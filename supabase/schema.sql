create table if not exists public.survey_nodes (
  id text not null,
  survey_id text not null,
  name text not null,
  type text not null check (type in (
    'entrance', 'corridor', 'junction', 'room',
    'staircase', 'elevator', 'landmark'
  )),
  floor integer not null,
  x double precision not null,
  y double precision not null,
  z double precision not null,
  cloud_anchor_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (survey_id, id)
);

alter table public.survey_nodes
  add column if not exists cloud_anchor_id text;

create table if not exists public.survey_floors (
  survey_id text not null,
  floor integer not null,
  name text not null,
  created_at timestamptz not null default now(),
  primary key (survey_id, floor)
);

insert into public.survey_floors (survey_id, floor, name)
select distinct survey_id, floor, 'Floor ' || floor::text
from public.survey_nodes
on conflict (survey_id, floor) do nothing;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'survey_nodes_floor_fk'
  ) then
    alter table public.survey_nodes
      add constraint survey_nodes_floor_fk
      foreign key (survey_id, floor)
      references public.survey_floors (survey_id, floor)
      on update cascade on delete restrict;
  end if;
end;
$$;

create table if not exists public.survey_connections (
  id text not null,
  survey_id text not null,
  node_a_id text not null,
  node_b_id text not null,
  connection_type text not null default 'corridor',
  created_at timestamptz not null default now(),
  primary key (survey_id, id),
  foreign key (survey_id, node_a_id)
    references public.survey_nodes (survey_id, id) on delete cascade,
  foreign key (survey_id, node_b_id)
    references public.survey_nodes (survey_id, id) on delete cascade,
  check (node_a_id < node_b_id)
);

alter table public.survey_connections
  add column if not exists connection_type text not null default 'corridor';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'survey_connections_type_check'
  ) then
    alter table public.survey_connections
      add constraint survey_connections_type_check
      check (connection_type in ('corridor', 'stairs', 'elevator'));
  end if;
end;
$$;

create unique index if not exists survey_connections_pair_idx
  on public.survey_connections (survey_id, node_a_id, node_b_id);

create index if not exists survey_nodes_survey_id_idx
  on public.survey_nodes (survey_id);

create index if not exists survey_floors_survey_id_idx
  on public.survey_floors (survey_id);

create index if not exists survey_connections_survey_id_idx
  on public.survey_connections (survey_id);

alter table public.survey_nodes enable row level security;
alter table public.survey_floors enable row level security;

-- This policy is suitable only while the app uses an anonymous survey id.
-- Replace it with auth.uid()-based policies before production deployment.
drop policy if exists "anonymous users can read survey nodes" on public.survey_nodes;
create policy "anonymous users can read survey nodes"
  on public.survey_nodes for select to anon using (true);

drop policy if exists "anonymous users can insert survey nodes" on public.survey_nodes;
create policy "anonymous users can insert survey nodes"
  on public.survey_nodes for insert to anon with check (true);

drop policy if exists "anonymous users can update survey nodes" on public.survey_nodes;
create policy "anonymous users can update survey nodes"
  on public.survey_nodes for update to anon using (true) with check (true);

drop policy if exists "anonymous users can delete survey nodes" on public.survey_nodes;
create policy "anonymous users can delete survey nodes"
  on public.survey_nodes for delete to anon using (true);

drop policy if exists "anonymous users can read survey floors" on public.survey_floors;
create policy "anonymous users can read survey floors"
  on public.survey_floors for select to anon using (true);

drop policy if exists "anonymous users can insert survey floors" on public.survey_floors;
create policy "anonymous users can insert survey floors"
  on public.survey_floors for insert to anon with check (true);

drop policy if exists "anonymous users can update survey floors" on public.survey_floors;
create policy "anonymous users can update survey floors"
  on public.survey_floors for update to anon using (true) with check (true);

drop policy if exists "anonymous users can delete survey floors" on public.survey_floors;
create policy "anonymous users can delete survey floors"
  on public.survey_floors for delete to anon using (true);

alter table public.survey_connections enable row level security;

drop policy if exists "anonymous users can read survey connections" on public.survey_connections;
create policy "anonymous users can read survey connections"
  on public.survey_connections for select to anon using (true);

drop policy if exists "anonymous users can insert survey connections" on public.survey_connections;
create policy "anonymous users can insert survey connections"
  on public.survey_connections for insert to anon with check (true);

drop policy if exists "anonymous users can update survey connections" on public.survey_connections;
create policy "anonymous users can update survey connections"
  on public.survey_connections for update to anon using (true) with check (true);

drop policy if exists "anonymous users can delete survey connections" on public.survey_connections;
create policy "anonymous users can delete survey connections"
  on public.survey_connections for delete to anon using (true);

create or replace function public.set_survey_nodes_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists survey_nodes_updated_at on public.survey_nodes;
create trigger survey_nodes_updated_at
before update on public.survey_nodes
for each row execute function public.set_survey_nodes_updated_at();
