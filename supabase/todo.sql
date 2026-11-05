-- Database for the notch's Todo tab: each person's own todo list.
-- Run once in the Supabase dashboard's SQL Editor, in the project Poke uses (after poke.sql).
-- Running it again is safe.
--
-- A todo belongs to the signed-in user, the same anonymous sign-in Poke uses. Row level security
-- lets you read and change only your own todos. At most 200 todos per person.

create table if not exists public.todos (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  is_done boolean not null default false,
  created_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists todos_user_id on public.todos (user_id, id);

alter table public.todos enable row level security;

drop policy if exists "Read own todos" on public.todos;
create policy "Read own todos" on public.todos
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "Add own todos" on public.todos;
create policy "Add own todos" on public.todos
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "Change own todos" on public.todos;
create policy "Change own todos" on public.todos
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "Delete own todos" on public.todos;
create policy "Delete own todos" on public.todos
  for delete to authenticated using (user_id = auth.uid());

revoke all on public.todos from anon;
grant select, insert, update, delete on public.todos to authenticated;

-- A todo's owner is always the signed-in user, its title is trimmed, and its times come from the
-- database: when it was added, and when it was ticked off.
create or replace function public.prepare_todo() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.user_id := auth.uid();
    new.created_at := now();
    if (select count(*) from todos where user_id = new.user_id) >= 200 then
      raise exception 'You have 200 todos, delete some first';
    end if;
  else
    new.user_id := old.user_id;
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

-- The API sees the new table right away, without waiting for its schema cache to refresh.
notify pgrst, 'reload schema';
