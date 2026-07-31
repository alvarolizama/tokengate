--
-- PostgreSQL database dump
--

\restrict UreA7k9w56Nig8JdokEiUO2fgHaVBODCWt6VRWUAFGgPChcy76dwCqaHdNBh5zs

-- Dumped from database version 18.3 (Homebrew)
-- Dumped by pg_dump version 18.3 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: oban_job_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.oban_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_keys (
    id uuid NOT NULL,
    team_member_id uuid NOT NULL,
    key_hash character varying(255) NOT NULL,
    key_prefix character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_logs (
    id uuid NOT NULL,
    user_id uuid,
    action character varying(255),
    entity_type character varying(255),
    entity_id character varying(255),
    changes jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL
);


--
-- Name: model_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_aliases (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    display_name character varying(255) NOT NULL,
    context_window integer NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: model_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_providers (
    id uuid NOT NULL,
    model_alias_id uuid NOT NULL,
    provider_model character varying(255) NOT NULL,
    priority integer,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    credential_id uuid NOT NULL,
    billing_mode character varying(255) DEFAULT 'pay_per_token'::character varying NOT NULL,
    context_window integer,
    exclusive_to_team_member_id uuid,
    exclusive_to_team_id uuid
);


--
-- Name: oban_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.oban_jobs (
    id bigint NOT NULL,
    state public.oban_job_state DEFAULT 'available'::public.oban_job_state NOT NULL,
    queue text DEFAULT 'default'::text NOT NULL,
    worker text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    errors jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    attempt integer DEFAULT 0 NOT NULL,
    max_attempts integer DEFAULT 20 NOT NULL,
    inserted_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    scheduled_at timestamp without time zone DEFAULT timezone('UTC'::text, now()) NOT NULL,
    attempted_at timestamp without time zone,
    completed_at timestamp without time zone,
    attempted_by text[],
    discarded_at timestamp without time zone,
    priority integer DEFAULT 0 NOT NULL,
    tags text[] DEFAULT ARRAY[]::text[],
    meta jsonb DEFAULT '{}'::jsonb,
    cancelled_at timestamp without time zone,
    CONSTRAINT attempt_range CHECK (((attempt >= 0) AND (attempt <= max_attempts))),
    CONSTRAINT positive_max_attempts CHECK ((max_attempts > 0)),
    CONSTRAINT queue_length CHECK (((char_length(queue) > 0) AND (char_length(queue) < 128))),
    CONSTRAINT worker_length CHECK (((char_length(worker) > 0) AND (char_length(worker) < 128)))
);


--
-- Name: TABLE oban_jobs; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.oban_jobs IS '14';


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.oban_jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: oban_jobs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.oban_jobs_id_seq OWNED BY public.oban_jobs.id;


--
-- Name: oban_peers; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.oban_peers (
    name text NOT NULL,
    node text NOT NULL,
    started_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL
);


--
-- Name: observability_destinations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.observability_destinations (
    id uuid NOT NULL,
    name character varying(255),
    type character varying(255) DEFAULT 'otlp_webhook'::character varying,
    url character varying(255),
    headers jsonb DEFAULT '{}'::jsonb,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    team_id uuid NOT NULL
);


--
-- Name: provider_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_credentials (
    id uuid NOT NULL,
    provider_id uuid NOT NULL,
    api_key_encrypted character varying(255) NOT NULL,
    max_rpm integer,
    max_concurrent integer,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    name character varying(255),
    error_reason character varying(255),
    error_at timestamp(0) without time zone,
    receive_timeout_ms integer DEFAULT 120000 NOT NULL,
    error_message character varying(255),
    CONSTRAINT provider_credentials_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'disabled'::character varying, 'error'::character varying])::text[])))
);


--
-- Name: providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.providers (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    base_url character varying(255) NOT NULL,
    billing_type character varying(255) DEFAULT 'pay_per_token'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL
);


--
-- Name: request_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs (
    id uuid NOT NULL,
    team_member_id uuid NOT NULL,
    provider_id uuid,
    model_alias_id uuid,
    model_requested character varying(255) NOT NULL,
    model_responded character varying(255),
    agent_type character varying(255) DEFAULT 'unknown'::character varying NOT NULL,
    status_code integer,
    prompt_tokens integer DEFAULT 0 NOT NULL,
    completion_tokens integer DEFAULT 0 NOT NULL,
    provider_cost_usd numeric(12,6),
    latency_ms integer,
    streaming boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    ttft_ms integer,
    model_provider_id uuid,
    think boolean DEFAULT false NOT NULL,
    effort character varying(255),
    api_key_prefix character varying(255),
    credential_name character varying(255),
    provider_status_code integer,
    error_reason character varying(255)
)
PARTITION BY RANGE (inserted_at);


--
-- Name: request_logs_2026_07_26; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_07_26 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    team_member_id uuid CONSTRAINT request_logs_team_member_id_not_null NOT NULL,
    provider_id uuid,
    model_alias_id uuid,
    model_requested character varying(255) CONSTRAINT request_logs_model_requested_not_null NOT NULL,
    model_responded character varying(255),
    agent_type character varying(255) DEFAULT 'unknown'::character varying CONSTRAINT request_logs_agent_type_not_null NOT NULL,
    status_code integer,
    prompt_tokens integer DEFAULT 0 CONSTRAINT request_logs_prompt_tokens_not_null NOT NULL,
    completion_tokens integer DEFAULT 0 CONSTRAINT request_logs_completion_tokens_not_null NOT NULL,
    provider_cost_usd numeric(12,6),
    latency_ms integer,
    streaming boolean DEFAULT false CONSTRAINT request_logs_streaming_not_null NOT NULL,
    inserted_at timestamp(0) without time zone CONSTRAINT request_logs_inserted_at_not_null NOT NULL,
    ttft_ms integer,
    model_provider_id uuid,
    think boolean DEFAULT false CONSTRAINT request_logs_think_not_null NOT NULL,
    effort character varying(255),
    api_key_prefix character varying(255),
    credential_name character varying(255),
    provider_status_code integer,
    error_reason character varying(255)
);


--
-- Name: request_logs_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_default (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    team_member_id uuid CONSTRAINT request_logs_team_member_id_not_null NOT NULL,
    provider_id uuid,
    model_alias_id uuid,
    model_requested character varying(255) CONSTRAINT request_logs_model_requested_not_null NOT NULL,
    model_responded character varying(255),
    agent_type character varying(255) DEFAULT 'unknown'::character varying CONSTRAINT request_logs_agent_type_not_null NOT NULL,
    status_code integer,
    prompt_tokens integer DEFAULT 0 CONSTRAINT request_logs_prompt_tokens_not_null NOT NULL,
    completion_tokens integer DEFAULT 0 CONSTRAINT request_logs_completion_tokens_not_null NOT NULL,
    provider_cost_usd numeric(12,6),
    latency_ms integer,
    streaming boolean DEFAULT false CONSTRAINT request_logs_streaming_not_null NOT NULL,
    inserted_at timestamp(0) without time zone CONSTRAINT request_logs_inserted_at_not_null NOT NULL,
    ttft_ms integer,
    model_provider_id uuid,
    think boolean DEFAULT false CONSTRAINT request_logs_think_not_null NOT NULL,
    effort character varying(255),
    api_key_prefix character varying(255),
    credential_name character varying(255),
    provider_status_code integer,
    error_reason character varying(255)
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: service_api_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_api_keys (
    id uuid NOT NULL,
    service_id uuid NOT NULL,
    key_hash character varying(255) NOT NULL,
    key_prefix character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: service_model_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_model_aliases (
    id uuid NOT NULL,
    service_id uuid NOT NULL,
    model_alias_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.services (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    monthly_budget_usd numeric(12,2),
    concurrency_limit integer DEFAULT 5 NOT NULL,
    rpm_limit integer DEFAULT 60 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: team_member_extra_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_member_extra_aliases (
    id uuid NOT NULL,
    team_member_id uuid NOT NULL,
    model_alias_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: team_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_members (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    team_id uuid NOT NULL,
    team_role character varying(255) DEFAULT 'user'::character varying NOT NULL,
    extra_monthly_budget_usd numeric(12,2),
    extra_concurrency integer,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    extra_rpm integer
);


--
-- Name: team_model_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.team_model_aliases (
    id uuid NOT NULL,
    team_id uuid NOT NULL,
    model_alias_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    monthly_budget_per_user_usd numeric(12,2),
    default_concurrency_limit integer DEFAULT 5 NOT NULL,
    default_rpm_limit integer DEFAULT 60 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email character varying(255) NOT NULL,
    name character varying(255),
    password_hash character varying(255),
    global_role character varying(255) DEFAULT 'user'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    google_id character varying(255),
    avatar_url character varying(255)
);


--
-- Name: request_logs_2026_07_26; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_07_26 FOR VALUES FROM ('2026-07-26 00:00:00') TO ('2026-07-27 00:00:00');


--
-- Name: request_logs_default; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_default DEFAULT;


--
-- Name: oban_jobs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs ALTER COLUMN id SET DEFAULT nextval('public.oban_jobs_id_seq'::regclass);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: audit_logs audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_pkey PRIMARY KEY (id);


--
-- Name: model_aliases model_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_aliases
    ADD CONSTRAINT model_aliases_pkey PRIMARY KEY (id);


--
-- Name: model_providers model_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_pkey PRIMARY KEY (id);


--
-- Name: oban_jobs non_negative_priority; Type: CHECK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.oban_jobs
    ADD CONSTRAINT non_negative_priority CHECK ((priority >= 0)) NOT VALID;


--
-- Name: oban_jobs oban_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_jobs
    ADD CONSTRAINT oban_jobs_pkey PRIMARY KEY (id);


--
-- Name: oban_peers oban_peers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.oban_peers
    ADD CONSTRAINT oban_peers_pkey PRIMARY KEY (name);


--
-- Name: observability_destinations observability_destinations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observability_destinations
    ADD CONSTRAINT observability_destinations_pkey PRIMARY KEY (id);


--
-- Name: provider_credentials provider_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_credentials
    ADD CONSTRAINT provider_credentials_pkey PRIMARY KEY (id);


--
-- Name: providers providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.providers
    ADD CONSTRAINT providers_pkey PRIMARY KEY (id);


--
-- Name: request_logs request_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs
    ADD CONSTRAINT request_logs_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_07_26 request_logs_2026_07_26_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_07_26
    ADD CONSTRAINT request_logs_2026_07_26_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_default request_logs_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_default
    ADD CONSTRAINT request_logs_default_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: service_api_keys service_api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_api_keys
    ADD CONSTRAINT service_api_keys_pkey PRIMARY KEY (id);


--
-- Name: service_model_aliases service_model_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_model_aliases
    ADD CONSTRAINT service_model_aliases_pkey PRIMARY KEY (id);


--
-- Name: services services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (id);


--
-- Name: team_member_extra_aliases team_member_extra_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_member_extra_aliases
    ADD CONSTRAINT team_member_extra_aliases_pkey PRIMARY KEY (id);


--
-- Name: team_members team_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members
    ADD CONSTRAINT team_members_pkey PRIMARY KEY (id);


--
-- Name: team_model_aliases team_model_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_model_aliases
    ADD CONSTRAINT team_model_aliases_pkey PRIMARY KEY (id);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: api_keys_key_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_keys_key_hash_index ON public.api_keys USING btree (key_hash);


--
-- Name: api_keys_team_member_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_keys_team_member_id_index ON public.api_keys USING btree (team_member_id);


--
-- Name: audit_logs_entity_type_entity_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_entity_type_entity_id_index ON public.audit_logs USING btree (entity_type, entity_id);


--
-- Name: audit_logs_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_inserted_at_index ON public.audit_logs USING btree (inserted_at);


--
-- Name: audit_logs_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX audit_logs_user_id_index ON public.audit_logs USING btree (user_id);


--
-- Name: model_aliases_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_aliases_name_index ON public.model_aliases USING btree (name);


--
-- Name: model_providers_credential_id_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_providers_credential_id_unique_index ON public.model_providers USING btree (credential_id);


--
-- Name: model_providers_model_alias_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX model_providers_model_alias_id_index ON public.model_providers USING btree (model_alias_id);


--
-- Name: oban_jobs_args_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_args_index ON public.oban_jobs USING gin (args);


--
-- Name: oban_jobs_meta_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_meta_index ON public.oban_jobs USING gin (meta);


--
-- Name: oban_jobs_state_cancelled_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_cancelled_at_index ON public.oban_jobs USING btree (state, cancelled_at);


--
-- Name: oban_jobs_state_discarded_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_discarded_at_index ON public.oban_jobs USING btree (state, discarded_at);


--
-- Name: oban_jobs_state_queue_priority_scheduled_at_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX oban_jobs_state_queue_priority_scheduled_at_id_index ON public.oban_jobs USING btree (state, queue, priority, scheduled_at, id);


--
-- Name: observability_destinations_team_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observability_destinations_team_id_index ON public.observability_destinations USING btree (team_id);


--
-- Name: provider_credentials_provider_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_credentials_provider_id_index ON public.provider_credentials USING btree (provider_id);


--
-- Name: request_logs_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_inserted_idx ON ONLY public.request_logs USING btree (inserted_at);


--
-- Name: request_logs_2026_07_26_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (inserted_at);


--
-- Name: request_logs_model_provider_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_model_provider_id_index ON ONLY public.request_logs USING btree (model_provider_id);


--
-- Name: request_logs_2026_07_26_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_model_provider_id_idx ON public.request_logs_2026_07_26 USING btree (model_provider_id);


--
-- Name: request_logs_team_member_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_team_member_inserted_idx ON ONLY public.request_logs USING btree (team_member_id, inserted_at);


--
-- Name: request_logs_2026_07_26_team_member_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_team_member_id_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (team_member_id, inserted_at);


--
-- Name: request_logs_default_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_inserted_at_idx ON public.request_logs_default USING btree (inserted_at);


--
-- Name: request_logs_default_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_model_provider_id_idx ON public.request_logs_default USING btree (model_provider_id);


--
-- Name: request_logs_default_team_member_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_team_member_id_inserted_at_idx ON public.request_logs_default USING btree (team_member_id, inserted_at);


--
-- Name: service_api_keys_key_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX service_api_keys_key_hash_index ON public.service_api_keys USING btree (key_hash);


--
-- Name: service_api_keys_service_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX service_api_keys_service_id_index ON public.service_api_keys USING btree (service_id);


--
-- Name: service_model_aliases_service_id_model_alias_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX service_model_aliases_service_id_model_alias_id_index ON public.service_model_aliases USING btree (service_id, model_alias_id);


--
-- Name: team_member_extra_aliases_team_member_id_model_alias_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX team_member_extra_aliases_team_member_id_model_alias_id_index ON public.team_member_extra_aliases USING btree (team_member_id, model_alias_id);


--
-- Name: team_members_team_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX team_members_team_id_index ON public.team_members USING btree (team_id);


--
-- Name: team_members_user_team_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX team_members_user_team_unique_index ON public.team_members USING btree (user_id, team_id);


--
-- Name: team_model_aliases_team_id_model_alias_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX team_model_aliases_team_id_model_alias_id_index ON public.team_model_aliases USING btree (team_id, model_alias_id);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_google_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_google_id_index ON public.users USING btree (google_id);


--
-- Name: request_logs_2026_07_26_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_07_26_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_07_26_model_provider_id_idx;


--
-- Name: request_logs_2026_07_26_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_07_26_pkey;


--
-- Name: request_logs_2026_07_26_team_member_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_team_member_inserted_idx ATTACH PARTITION public.request_logs_2026_07_26_team_member_id_inserted_at_idx;


--
-- Name: request_logs_default_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_default_inserted_at_idx;


--
-- Name: request_logs_default_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_default_model_provider_id_idx;


--
-- Name: request_logs_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_default_pkey;


--
-- Name: request_logs_default_team_member_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_team_member_inserted_idx ATTACH PARTITION public.request_logs_default_team_member_id_inserted_at_idx;


--
-- Name: api_keys api_keys_team_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES public.team_members(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: model_providers model_providers_credential_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_credential_id_fkey FOREIGN KEY (credential_id) REFERENCES public.provider_credentials(id);


--
-- Name: model_providers model_providers_exclusive_to_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_exclusive_to_team_id_fkey FOREIGN KEY (exclusive_to_team_id) REFERENCES public.teams(id) ON DELETE CASCADE;


--
-- Name: model_providers model_providers_exclusive_to_team_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_exclusive_to_team_member_id_fkey FOREIGN KEY (exclusive_to_team_member_id) REFERENCES public.team_members(id) ON DELETE CASCADE;


--
-- Name: model_providers model_providers_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES public.model_aliases(id);


--
-- Name: observability_destinations observability_destinations_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observability_destinations
    ADD CONSTRAINT observability_destinations_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- Name: provider_credentials provider_credentials_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_credentials
    ADD CONSTRAINT provider_credentials_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id);


--
-- Name: request_logs request_logs_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.request_logs
    ADD CONSTRAINT request_logs_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES public.model_aliases(id) ON DELETE SET NULL;


--
-- Name: request_logs request_logs_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.request_logs
    ADD CONSTRAINT request_logs_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id) ON DELETE SET NULL;


--
-- Name: request_logs request_logs_team_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.request_logs
    ADD CONSTRAINT request_logs_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES public.team_members(id) ON DELETE CASCADE;


--
-- Name: service_api_keys service_api_keys_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_api_keys
    ADD CONSTRAINT service_api_keys_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: service_model_aliases service_model_aliases_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_model_aliases
    ADD CONSTRAINT service_model_aliases_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES public.model_aliases(id) ON DELETE CASCADE;


--
-- Name: service_model_aliases service_model_aliases_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_model_aliases
    ADD CONSTRAINT service_model_aliases_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: team_member_extra_aliases team_member_extra_aliases_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_member_extra_aliases
    ADD CONSTRAINT team_member_extra_aliases_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES public.model_aliases(id) ON DELETE CASCADE;


--
-- Name: team_member_extra_aliases team_member_extra_aliases_team_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_member_extra_aliases
    ADD CONSTRAINT team_member_extra_aliases_team_member_id_fkey FOREIGN KEY (team_member_id) REFERENCES public.team_members(id);


--
-- Name: team_members team_members_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members
    ADD CONSTRAINT team_members_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- Name: team_members team_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_members
    ADD CONSTRAINT team_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: team_model_aliases team_model_aliases_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_model_aliases
    ADD CONSTRAINT team_model_aliases_model_alias_id_fkey FOREIGN KEY (model_alias_id) REFERENCES public.model_aliases(id) ON DELETE CASCADE;


--
-- Name: team_model_aliases team_model_aliases_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.team_model_aliases
    ADD CONSTRAINT team_model_aliases_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.teams(id);


--
-- PostgreSQL database dump complete
--

\unrestrict UreA7k9w56Nig8JdokEiUO2fgHaVBODCWt6VRWUAFGgPChcy76dwCqaHdNBh5zs

INSERT INTO public."schema_migrations" (version) VALUES (20260725210000);
INSERT INTO public."schema_migrations" (version) VALUES (20260725220000);
INSERT INTO public."schema_migrations" (version) VALUES (20260725220100);
INSERT INTO public."schema_migrations" (version) VALUES (20260725220200);
INSERT INTO public."schema_migrations" (version) VALUES (20260725220300);
INSERT INTO public."schema_migrations" (version) VALUES (20260725220400);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230001);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230002);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230003);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230004);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230005);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230006);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230007);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230008);
INSERT INTO public."schema_migrations" (version) VALUES (20260725230009);
INSERT INTO public."schema_migrations" (version) VALUES (20260726000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260726000002);
INSERT INTO public."schema_migrations" (version) VALUES (20260726000003);
INSERT INTO public."schema_migrations" (version) VALUES (20260726202336);
INSERT INTO public."schema_migrations" (version) VALUES (20260726203708);
INSERT INTO public."schema_migrations" (version) VALUES (20260726214614);
INSERT INTO public."schema_migrations" (version) VALUES (20260726222126);
INSERT INTO public."schema_migrations" (version) VALUES (20260727005106);
INSERT INTO public."schema_migrations" (version) VALUES (20260727010611);
INSERT INTO public."schema_migrations" (version) VALUES (20260727014606);
INSERT INTO public."schema_migrations" (version) VALUES (20260727022339);
INSERT INTO public."schema_migrations" (version) VALUES (20260727031453);
INSERT INTO public."schema_migrations" (version) VALUES (20260727033325);
INSERT INTO public."schema_migrations" (version) VALUES (20260727035036);
INSERT INTO public."schema_migrations" (version) VALUES (20260727041837);
INSERT INTO public."schema_migrations" (version) VALUES (20260727050903);
INSERT INTO public."schema_migrations" (version) VALUES (20260727052739);
INSERT INTO public."schema_migrations" (version) VALUES (20260727125200);
INSERT INTO public."schema_migrations" (version) VALUES (20260727132747);
INSERT INTO public."schema_migrations" (version) VALUES (20260727173824);
INSERT INTO public."schema_migrations" (version) VALUES (20260728002914);
INSERT INTO public."schema_migrations" (version) VALUES (20260728010000);
INSERT INTO public."schema_migrations" (version) VALUES (20260728020000);
INSERT INTO public."schema_migrations" (version) VALUES (20260728030000);
INSERT INTO public."schema_migrations" (version) VALUES (20260728040000);
INSERT INTO public."schema_migrations" (version) VALUES (20260728042237);
INSERT INTO public."schema_migrations" (version) VALUES (20260728053658);
INSERT INTO public."schema_migrations" (version) VALUES (20260728053759);
INSERT INTO public."schema_migrations" (version) VALUES (20260728071514);
INSERT INTO public."schema_migrations" (version) VALUES (20260729024003);
INSERT INTO public."schema_migrations" (version) VALUES (20260729040427);
INSERT INTO public."schema_migrations" (version) VALUES (20260729064718);
INSERT INTO public."schema_migrations" (version) VALUES (20260729232802);
INSERT INTO public."schema_migrations" (version) VALUES (20260730212621);
INSERT INTO public."schema_migrations" (version) VALUES (20260731000001);
INSERT INTO public."schema_migrations" (version) VALUES (20260731044440);
