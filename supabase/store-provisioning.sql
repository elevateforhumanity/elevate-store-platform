
create table public.store_customers (
 id uuid primary key default gen_random_uuid(),
 identity_issuer text not null,
 identity_subject text not null,
 created_at timestamptz not null default now(),
 unique(identity_issuer, identity_subject)
);
create table public.store_subscriptions (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.store_customers(id),
 provider text not null check(provider in ('paypal','quickbooks')),
 provider_subscription_id text not null,
 product_code text not null,
 status text not null check(status in ('pending','active','past_due','suspended','cancelled')),
 verified_at timestamptz,
 created_at timestamptz not null default now(),
 unique(provider, provider_subscription_id),
 check(status <> 'active' or verified_at is not null)
);
create table public.store_websites (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.store_customers(id),
 subscription_id uuid not null references public.store_subscriptions(id),
 slug text not null unique check(slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
 status text not null default 'pending' check(status in ('pending','provisioning','ready','failed','suspended')),
 created_at timestamptz not null default now()
);
create table public.store_payment_events (
 id uuid primary key default gen_random_uuid(),
 provider text not null check(provider in ('paypal','quickbooks')),
 provider_event_id text not null,
 subscription_id uuid references public.store_subscriptions(id),
 verified_at timestamptz not null,
 processed_at timestamptz,
 created_at timestamptz not null default now(),
 unique(provider, provider_event_id)
);
create table public.store_provisioning_jobs (
 id uuid primary key default gen_random_uuid(),
 website_id uuid not null unique references public.store_websites(id),
 status text not null default 'queued' check(status in ('queued','processing','completed','failed','needs_review')),
 attempts integer not null default 0 check(attempts >= 0),
 lease_expires_at timestamptz,
 next_attempt_at timestamptz not null default now(),
 last_error_code text,
 created_at timestamptz not null default now()
);
create table public.store_provisioned_resources (
 id uuid primary key default gen_random_uuid(),
 website_id uuid not null references public.store_websites(id),
 resource_type text not null check(resource_type in ('github_repository','supabase_project','google_cloud_service')),
 provider_resource_id text not null,
 status text not null check(status in ('creating','ready','failed')),
 created_at timestamptz not null default now(),
 unique(website_id, resource_type),
 unique(resource_type, provider_resource_id)
);
create index store_subscriptions_customer_idx on public.store_subscriptions(customer_id);
create index store_websites_customer_idx on public.store_websites(customer_id);
create index store_websites_subscription_idx on public.store_websites(subscription_id);
create index store_payment_events_subscription_idx on public.store_payment_events(subscription_id);
create index store_provisioning_jobs_claim_idx on public.store_provisioning_jobs(status,next_attempt_at);
do $$
declare t text;
begin
 foreach t in array array['store_customers','store_subscriptions','store_websites','store_payment_events','store_provisioning_jobs','store_provisioned_resources'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('revoke all on public.%I from anon, authenticated',t);
  execute format('grant select, insert, update, delete on public.%I to service_role',t);
 end loop;
end $$;
comment on table public.store_customers is 'Server-only customer identity mapping. Identity must be verified by the store backend; no cross-project auth foreign key.';
comment on table public.store_provisioned_resources is 'Resource identifiers only. Credentials belong in Secret Manager and must never be stored here.';


alter table public.store_subscriptions add constraint store_subscription_owner unique(id,customer_id);
alter table public.store_websites add constraint store_website_subscription_owner foreign key(subscription_id,customer_id) references public.store_subscriptions(id,customer_id);
create function public.store_enqueue_website(p_website_id uuid)
returns uuid language plpgsql security invoker set search_path=public,pg_temp as $$
declare job_id uuid;
begin
 perform 1 from public.store_websites w join public.store_subscriptions s on s.id=w.subscription_id
 where w.id=p_website_id and w.customer_id=s.customer_id and s.status='active' and s.verified_at is not null
 and exists(select 1 from public.store_payment_events e where e.subscription_id=s.id and e.verified_at is not null)
 for update of w,s;
 if not found then raise exception 'Verified active subscription and payment event required'; end if;
 insert into public.store_provisioning_jobs(website_id) values(p_website_id)
 on conflict(website_id) do update set website_id=excluded.website_id returning id into job_id;
 return job_id;
end $$;
revoke all on function public.store_enqueue_website(uuid) from public,anon,authenticated;
grant execute on function public.store_enqueue_website(uuid) to service_role;
create function public.store_claim_provisioning_job()
returns setof public.store_provisioning_jobs language sql security invoker set search_path=public,pg_temp as $$
 update public.store_provisioning_jobs j
 set status='processing',attempts=attempts+1,lease_expires_at=now()+interval '10 minutes'
 where j.id=(
  select q.id from public.store_provisioning_jobs q
  join public.store_websites w on w.id=q.website_id
  join public.store_subscriptions s on s.id=w.subscription_id
  where q.status='queued' and q.next_attempt_at<=now() and s.status='active' and s.verified_at is not null
  and exists(select 1 from public.store_payment_events e where e.subscription_id=s.id and e.verified_at is not null)
  order by q.created_at for update of q skip locked limit 1
 ) returning j.*;
$$;
revoke all on function public.store_claim_provisioning_job() from public,anon,authenticated;
grant execute on function public.store_claim_provisioning_job() to service_role;
