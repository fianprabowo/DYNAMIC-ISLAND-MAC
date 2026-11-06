-- Database for the notch's Todo tab: your own todos, and todos shared with a friend, each with an
-- optional date and time it's due.
-- Run once in the Supabase dashboard's SQL Editor, in the project Poke uses (after poke.sql).
-- Running it again is safe, and brings a project that ran an older version up to date.
--
-- A todo belongs to the signed-in user who added it, the same anonymous sign-in Poke uses. A
-- shared todo also names the friend it's shared with: both of you can see it, tick it off and
-- delete it. Only friends can be shared with. Row level security keeps everyone else out.
-- At most 200 todos added per person.

create table if not exists public.todos (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  is_done boolean not null default false,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
alter table public.todos add column if not exists friend_id uuid references public.profiles on delete cascade;
alter table public.todos add column if not exists due_at timestamptz;
create index if not exists todos_user_id on public.todos (user_id, id);
create index if not exists todos_friend_id on public.todos (friend_id, id);

alter table public.todos enable row level security;

drop policy if exists "Read own todos" on public.todos;
drop policy if exists "Read own and shared todos" on public.todos;
create policy "Read own and shared todos" on public.todos
  for select to authenticated using (user_id = auth.uid() or friend_id = auth.uid());

drop policy if exists "Add own todos" on public.todos;
create policy "Add own todos" on public.todos
  for insert to authenticated with check (
    user_id = auth.uid()
    and (friend_id is null
         or exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = todos.friend_id))
  );

drop policy if exists "Change own todos" on public.todos;
drop policy if exists "Change own and shared todos" on public.todos;
create policy "Change own and shared todos" on public.todos
  for update to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid())
  with check (user_id = auth.uid() or friend_id = auth.uid());

drop policy if exists "Delete own todos" on public.todos;
drop policy if exists "Delete own and shared todos" on public.todos;
create policy "Delete own and shared todos" on public.todos
  for delete to authenticated using (user_id = auth.uid() or friend_id = auth.uid());

revoke all on public.todos from anon;
grant select, insert, update, delete on public.todos to authenticated;

-- A todo's adder is always the signed-in user, and who it's shared with never changes. Its title
-- is trimmed, and its times come from the database: when it was added, and when it was ticked off.
create or replace function public.prepare_todo() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.created_at := now();
    if new.friend_id = new.user_id then
      raise exception 'Share a todo with a friend, not yourself';
    end if;
    if (select count(*) from todos where user_id = new.user_id) >= 200 then
      raise exception 'You have 200 todos, delete some first';
    end if;
  else
    new.user_id := old.user_id;
    new.friend_id := old.friend_id;
    new.created_at := old.created_at;
  end if;
  new.title := btrim(new.title);
  if not new.is_done then
    new.done_at := null;
  elsif tg_op = 'INSERT' or not old.is_done then
    new.done_at := now();
  else
    new.done_at := old.done_at;
  end if;
  return new;
end $$;

drop trigger if exists prepare_todo on public.todos;
create trigger prepare_todo before insert or update on public.todos
  for each row execute function public.prepare_todo();

-- Changes to shared todos reach the friend's notch right away.
do $$
begin
  alter publication supabase_realtime add table public.todos;
exception when duplicate_object then null;
end $$;

-- The API sees the new table and columns right away, without waiting for its schema cache.
notify pgrst, 'reload schema';
