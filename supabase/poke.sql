-- Database for Poke: friends send each other a nudge that drops down their notch.
-- Run once in the Supabase dashboard's SQL Editor. Running it again is safe.
--
-- Everyone signs in anonymously and has a profile with a name and a friend code. Entering a
-- friend's code makes both of you friends. Row level security lets you read only your own
-- profile, your friends and the pokes you sent or got, and poke only your friends.

create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 40),
  friend_code text not null unique,
  created_at timestamptz not null default now()
);

create table if not exists public.friendships (
  user_id uuid not null references public.profiles on delete cascade,
  friend_id uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);

create table if not exists public.pokes (
  id bigint generated always as identity primary key,
  sender_id uuid not null references public.profiles on delete cascade,
  sender_name text not null,
  recipient_id uuid not null references public.profiles on delete cascade,
  message text not null default '' check (char_length(message) <= 100),
  created_at timestamptz not null default now()
);
create index if not exists pokes_recipient_id on public.pokes (recipient_id, id);
create index if not exists pokes_sender_created on public.pokes (sender_id, created_at);

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.pokes enable row level security;

drop policy if exists "Read own profile" on public.profiles;
create policy "Read own profile" on public.profiles
  for select to authenticated using (id = auth.uid());

drop policy if exists "Read own friendships" on public.friendships;
create policy "Read own friendships" on public.friendships
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "Read sent and received pokes" on public.pokes;
create policy "Read sent and received pokes" on public.pokes
  for select to authenticated using (recipient_id = auth.uid() or sender_id = auth.uid());

drop policy if exists "Poke friends" on public.pokes;
create policy "Poke friends" on public.pokes
  for insert to authenticated with check (
    sender_id = auth.uid()
    and exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = recipient_id)
  );

-- Profiles and friendships change only through the functions below.
revoke insert, update, delete on public.profiles, public.friendships from anon, authenticated;
revoke update, delete on public.pokes from anon, authenticated;

-- A poke's sender is always the signed-in user, named from their profile. At most 10 a minute,
-- and pokes older than a week are deleted.
create or replace function public.prepare_poke() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.sender_id := auth.uid();
  select name into new.sender_name from profiles where id = new.sender_id;
  if new.sender_name is null then
    raise exception 'Set your name first';
  end if;
  if (select count(*) from pokes where sender_id = new.sender_id and created_at > now() - interval '1 minute') >= 10 then
    raise exception 'Too many pokes, wait a minute';
  end if;
  new.created_at := now();
  delete from pokes where created_at < now() - interval '7 days';
  return new;
end $$;

drop trigger if exists prepare_poke on public.pokes;
create trigger prepare_poke before insert on public.pokes
  for each row execute function public.prepare_poke();

-- Creates or renames the signed-in user's profile; a new one gets a friend code like K7QX-M2PA.
create or replace function public.set_profile(new_name text)
returns table (id uuid, name text, friend_code text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  new_name := btrim(new_name);
  if exists (select 1 from profiles p where p.id = auth.uid()) then
    update profiles p set name = new_name where p.id = auth.uid();
  else
    loop
      code := '';
      for i in 1..8 loop
        code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
      end loop;
      code := substr(code, 1, 4) || '-' || substr(code, 5, 4);
      exit when not exists (select 1 from profiles p where p.friend_code = code);
    end loop;
    insert into profiles (id, name, friend_code) values (auth.uid(), new_name, code);
  end if;
  return query select p.id, p.name, p.friend_code from profiles p where p.id = auth.uid();
end $$;

-- Makes the signed-in user and the owner of the code friends of each other.
create or replace function public.add_friend(code text)
returns table (id uuid, name text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  friend profiles;
begin
  if not exists (select 1 from profiles p where p.id = auth.uid()) then
    raise exception 'Set your name first';
  end if;
  select * into friend from profiles p where p.friend_code = upper(btrim(code));
  if friend.id is null then
    raise exception 'No one has that code';
  end if;
  if friend.id = auth.uid() then
    raise exception 'That is your own code';
  end if;
  insert into friendships (user_id, friend_id) values (auth.uid(), friend.id), (friend.id, auth.uid())
    on conflict do nothing;
  return query select friend.id, friend.name;
end $$;

create or replace function public.remove_friend(friend uuid) returns void
language sql security definer set search_path = public as $$
  delete from friendships
  where (user_id = auth.uid() and friend_id = friend) or (user_id = friend and friend_id = auth.uid());
$$;

create or replace function public.list_friends()
returns table (id uuid, name text)
language sql stable security definer set search_path = public as $$
  select p.id, p.name from friendships f join profiles p on p.id = f.friend_id
  where f.user_id = auth.uid()
  order by p.name;
$$;

revoke execute on function public.set_profile, public.add_friend, public.remove_friend, public.list_friends from public, anon;
grant execute on function public.set_profile, public.add_friend, public.remove_friend, public.list_friends to authenticated;

-- New pokes reach the recipient's notch right away.
do $$
begin
  alter publication supabase_realtime add table public.pokes;
exception when duplicate_object then null;
end $$;
