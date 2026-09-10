-- ============================================================================
-- Rotopa · 00 extensions
-- Enables the Postgres features the accounting core relies on.
-- ============================================================================

create extension if not exists pgcrypto      with schema extensions;  -- gen_random_uuid()
create extension if not exists ltree         with schema extensions;  -- account tree paths / fast subtree queries
create extension if not exists citext        with schema extensions;  -- case-insensitive codes / emails
create extension if not exists pg_trgm       with schema extensions;  -- fuzzy search on names
create extension if not exists btree_gist    with schema extensions;  -- exclusion constraints (period overlap)

-- Dedicated schema for internal helpers that must never be exposed over the API.
create schema if not exists app;

comment on schema app is 'Rotopa internal helpers (authorization, guards). Not exposed via PostgREST.';
