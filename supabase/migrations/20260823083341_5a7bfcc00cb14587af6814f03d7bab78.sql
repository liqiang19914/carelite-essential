drop policy if exists stores_operator_select on public.stores;
create policy stores_operator_select on public.stores
  for select using (
    auth.uid() in (
      select m.user_id from public.store_members m
      where m.store_id = stores.id and m.status = 'active'
    )
  );

drop policy if exists spg_operator_select on public.store_product_grants;
create policy spg_operator_select on public.store_product_grants
  for select using (
    store_id in (
      select m.store_id from public.store_members m
      where m.user_id = auth.uid() and m.status = 'active'
    )
  );

create unique index if not exists user_store_bindings_one_active_idx
  on public.user_store_bindings (user_id) where status = 'active';

create unique index if not exists store_members_one_owner_idx
  on public.store_members (store_id) where role = 'owner' and status = 'active';

drop function if exists public.join_store_as_clerk(uuid);