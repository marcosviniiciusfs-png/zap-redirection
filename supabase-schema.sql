create extension if not exists pgcrypto;

create table if not exists public.redirect_groups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  slug text not null,
  name text not null,
  whatsapp_number text not null,
  pixel_id text,
  capi_endpoint text,
  capi_access_token text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, slug)
);

alter table public.redirect_groups
add column if not exists capi_access_token text;

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

create or replace function public.log_redirect_event(
  p_user_id uuid,
  p_group_slug text,
  p_link_slug text,
  p_event_name text,
  p_event_id text,
  p_pixel_id text,
  p_campaign_name text,
  p_event_source_url text,
  p_user_agent text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.redirect_groups
    join public.redirect_links
      on redirect_links.group_id = redirect_groups.id
    where redirect_groups.user_id = p_user_id
      and redirect_groups.slug = p_group_slug
      and redirect_links.slug = p_link_slug
  ) then
    return;
  end if;

  insert into public.redirect_events (
    user_id,
    group_slug,
    link_slug,
    event_name,
    event_id,
    pixel_id,
    campaign_name,
    event_source_url,
    user_agent,
    payload
  )
  values (
    p_user_id,
    p_group_slug,
    p_link_slug,
    p_event_name,
    p_event_id,
    p_pixel_id,
    p_campaign_name,
    p_event_source_url,
    p_user_agent,
    coalesce(p_payload, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.log_redirect_event(uuid, text, text, text, text, text, text, text, text, jsonb) from public;
grant execute on function public.log_redirect_event(uuid, text, text, text, text, text, text, text, text, jsonb) to anon, authenticated;

create index if not exists redirect_groups_user_slug_idx on public.redirect_groups(user_id, slug);
create index if not exists redirect_links_group_slug_idx on public.redirect_links(group_id, slug);
create index if not exists redirect_events_group_link_idx on public.redirect_events(group_slug, link_slug, created_at desc);
