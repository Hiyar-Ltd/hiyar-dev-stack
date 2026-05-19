#!/usr/bin/env bash
# Creates one DB role per service with access restricted to its own schema.
# Runs automatically on first postgres container start (docker-entrypoint-initdb.d).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Required extensions
    CREATE EXTENSION IF NOT EXISTS postgis;
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
    CREATE EXTENSION IF NOT EXISTS btree_gin;
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

    -- Service schemas
    CREATE SCHEMA IF NOT EXISTS users;
    CREATE SCHEMA IF NOT EXISTS listings;
    CREATE SCHEMA IF NOT EXISTS search;
    CREATE SCHEMA IF NOT EXISTS bookings;
    CREATE SCHEMA IF NOT EXISTS payments;
    CREATE SCHEMA IF NOT EXISTS handovers;
    CREATE SCHEMA IF NOT EXISTS reviews;
    CREATE SCHEMA IF NOT EXISTS risk;
    CREATE SCHEMA IF NOT EXISTS ai;

    -- Service roles (password = role name for local dev only)
    CREATE ROLE user_svc      LOGIN PASSWORD 'user_svc';
    CREATE ROLE listing_svc   LOGIN PASSWORD 'listing_svc';
    CREATE ROLE search_svc    LOGIN PASSWORD 'search_svc';
    CREATE ROLE booking_svc   LOGIN PASSWORD 'booking_svc';
    CREATE ROLE payment_svc   LOGIN PASSWORD 'payment_svc';
    CREATE ROLE handover_svc  LOGIN PASSWORD 'handover_svc';
    CREATE ROLE review_svc    LOGIN PASSWORD 'review_svc';
    CREATE ROLE risk_svc      LOGIN PASSWORD 'risk_svc';
    CREATE ROLE ai_svc        LOGIN PASSWORD 'ai_svc';

    -- admin-service gets read-only access to all schemas
    CREATE ROLE admin_svc     LOGIN PASSWORD 'admin_svc';

    -- Grant schema usage + table privileges to each role
    GRANT USAGE ON SCHEMA users      TO user_svc;
    GRANT USAGE ON SCHEMA listings   TO listing_svc;
    GRANT USAGE ON SCHEMA search     TO search_svc;
    GRANT USAGE ON SCHEMA bookings   TO booking_svc;
    GRANT USAGE ON SCHEMA payments   TO payment_svc;
    GRANT USAGE ON SCHEMA handovers  TO handover_svc;
    GRANT USAGE ON SCHEMA reviews    TO review_svc;
    GRANT USAGE ON SCHEMA risk       TO risk_svc;
    GRANT USAGE ON SCHEMA ai         TO ai_svc;

    -- Default privileges: future tables inherit grants automatically
    ALTER DEFAULT PRIVILEGES IN SCHEMA users     GRANT ALL ON TABLES TO user_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA listings  GRANT ALL ON TABLES TO listing_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA search    GRANT ALL ON TABLES TO search_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA bookings  GRANT ALL ON TABLES TO booking_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA payments  GRANT ALL ON TABLES TO payment_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA handovers GRANT ALL ON TABLES TO handover_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA reviews   GRANT ALL ON TABLES TO review_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA risk      GRANT ALL ON TABLES TO risk_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA ai        GRANT ALL ON TABLES TO ai_svc;

    -- admin-service: read-only on all schemas
    GRANT USAGE ON SCHEMA users, listings, search, bookings, payments, handovers, reviews, risk, ai TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA users     GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA listings  GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA search    GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA bookings  GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA payments  GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA handovers GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA reviews   GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA risk      GRANT SELECT ON TABLES TO admin_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA ai        GRANT SELECT ON TABLES TO admin_svc;

    -- Outbox relay sidecar needs access to each service's outbox_events table.
    -- Grant the service role access to its own schema sequences (needed for UUID gen).
    ALTER DEFAULT PRIVILEGES IN SCHEMA users     GRANT ALL ON SEQUENCES TO user_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA listings  GRANT ALL ON SEQUENCES TO listing_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA bookings  GRANT ALL ON SEQUENCES TO booking_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA payments  GRANT ALL ON SEQUENCES TO payment_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA handovers GRANT ALL ON SEQUENCES TO handover_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA reviews   GRANT ALL ON SEQUENCES TO review_svc;
    ALTER DEFAULT PRIVILEGES IN SCHEMA risk      GRANT ALL ON SEQUENCES TO risk_svc;
EOSQL
