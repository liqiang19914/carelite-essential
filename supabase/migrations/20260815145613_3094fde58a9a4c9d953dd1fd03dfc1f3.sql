create table if not exists public.product_cover_fetch_limits (
  caller_id uuid primary key,
  window_start timestamptz not null default now(),
  request_count int not null default 0
);

alter table public.product_cover_fetch_limits enable row level security;

create or replace function public.check_product_cover_rate_limit(p_caller_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  insert into public.product_cover_fetch_limits (caller_id, window_start, request_count)
  values (p_caller_id, now(), 1)
  on conflict (caller_id) do update
    set request_count = case
          when public.product_cover_fetch_limits.window_start < now() - interval '1 minute'
          then 1
          else public.product_cover_fetch_limits.request_count + 1
        end,
        window_start = case
          when public.product_cover_fetch_limits.window_start < now() - interval '1 minute'
          then now()
          else public.product_cover_fetch_limits.window_start
        end
  returning (request_count <= 30);
$$;

revoke all on function public.check_product_cover_rate_limit(uuid) from public;
grant execute on function public.check_product_cover_rate_limit(uuid) to service_role;