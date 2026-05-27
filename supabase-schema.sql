create extension if not exists pgcrypto;

create table if not exists public.redirect_groups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  slug text not null,
  name text not null,
  whatsapp_number text not null,
  pixel_id text,
  capi_endpoint text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, slug)
);

create table if not exists public.redirect_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  group_id uuid not null references public.redirect_groups(id) on delete cascade,
  slug text not null,
  name text not null,
  message text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (group_id, slug)
);

create table if not exists public.redirect_events (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id) on delete set null,
  group_slug text,
  link_slug text,
  event_name text not null,
  event_id text,
  pixel_id text,
  campaign_name text,
  event_source_url text,
  user_agent text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists redirect_groups_updated_at on public.redirect_groups;
create trigger redirect_groups_updated_at
before update on public.redirect_groups
for each row execute function public.set_updated_at();

drop trigger if exists redirect_links_updated_at on public.redirect_links;
create trigger redirect_links_updated_at
before update on public.redirect_links
for each row execute function public.set_updated_at();

alter table public.redirect_groups enable row level security;
alter table public.redirect_links enable row level security;
alter table public.redirect_events enable row level security;

drop policy if exists "Users manage own redirect groups" on public.redirect_groups;
create policy "Users manage own redirect groups"
on public.redirect_groups
for all
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "Users manage own redirect links" on public.redirect_links;
create policy "Users manage own redirect links"
on public.redirect_links
for all
using (auth.uid() = user_id)
with check (
  auth.uid() = user_id
  and exists (
    select 1
    from public.redirect_groups
    where redirect_groups.id = redirect_links.group_id
      and redirect_groups.user_id = auth.uid()
  )
);

drop policy if exists "Users read own redirect events" on public.redirect_events;
create policy "Users read own redirect events"
on public.redirect_events
for select
using (auth.uid() = user_id);

create index if not exists redirect_groups_user_slug_idx on public.redirect_groups(user_id, slug);
create index if not exists redirect_links_group_slug_idx on public.redirect_links(group_id, slug);
create index if not exists redirect_events_group_link_idx on public.redirect_events(group_slug, link_slug, created_at desc);
