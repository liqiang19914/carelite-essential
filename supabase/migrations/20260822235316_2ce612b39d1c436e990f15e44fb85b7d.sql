insert into public.store_members (store_id, user_id, role, status, created_at, updated_at)
select s.id, s.operator_user_id, 'owner', 'active', now(), now()
from public.stores s
where s.operator_user_id is not null
on conflict (store_id, user_id) do nothing;

alter table public.store_members enable row level security;
alter table public.user_store_bindings enable row level security;

create policy store_members_select_self on public.store_members
  for select
  using (
    auth.uid() = user_id
    or auth.uid() in (
      select m.user_id from public.store_members m
      where m.store_id = store_members.store_id and m.status = 'active'
    )
  );

create policy user_store_bindings_select_self on public.user_store_bindings
  for select
  using (auth.uid() = user_id);