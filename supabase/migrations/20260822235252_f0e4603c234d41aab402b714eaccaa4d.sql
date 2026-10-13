create table if not exists public.store_members (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'clerk' check (role in ('owner','admin','clerk')),
  status text not null default 'active' check (status in ('active','disabled')),
  invited_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint store_members_unique unique (store_id, user_id)
);

create index if not exists store_members_user_idx on public.store_members(user_id, status);

create table if not exists public.user_store_bindings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  store_id uuid not null references public.stores(id) on delete cascade,
  status text not null default 'active' check (status in ('active','unbound')),
  bound_at timestamptz not null default now(),
  last_visit_at timestamptz,
  created_at timestamptz not null default now(),
  constraint user_store_bindings_unique unique (user_id, store_id)
);

create index if not exists user_store_bindings_user_idx on public.user_store_bindings(user_id, status);
create index if not exists user_store_bindings_store_idx on public.user_store_bindings(store_id, status);