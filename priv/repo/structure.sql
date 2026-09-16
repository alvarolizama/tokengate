--
-- PostgreSQL database dump
--

\restrict c54Iy3KJwzbUoVce0G66H7zI2WZ1thVEt5nbet6iDSC5437GyRvogyv8npAT1Yw

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
    group_member_id uuid,
    key_hash character varying(255) NOT NULL,
    key_prefix character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    subject_type character varying(255) DEFAULT 'member'::character varying NOT NULL,
    service_id uuid
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
-- Name: budget_exemptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.budget_exemptions (
    id uuid NOT NULL,
    scope character varying(255) NOT NULL,
    subject_type character varying(255) NOT NULL,
    user_id uuid,
    group_id uuid,
    service_id uuid,
    note character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: catalog_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_providers (
    key character varying(255) NOT NULL,
    name character varying(255),
    base_url character varying(255),
    doc_url character varying(255),
    logo_url character varying(255),
    env character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    npm character varying(255),
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    fingerprint character varying(255),
    fetched_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: catalog_sync_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_sync_state (
    id integer NOT NULL,
    synced_at timestamp(0) without time zone,
    source character varying(255),
    inserted integer DEFAULT 0 NOT NULL,
    updated integer DEFAULT 0 NOT NULL,
    unchanged integer DEFAULT 0 NOT NULL,
    stale integer DEFAULT 0 NOT NULL,
    error character varying(255),
    warnings jsonb[] DEFAULT ARRAY[]::jsonb[] NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: credit_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.credit_subscriptions (
    id uuid NOT NULL,
    user_id uuid,
    name character varying(255),
    units bigint DEFAULT 0 NOT NULL,
    recurrence character varying(255) DEFAULT 'monthly'::character varying NOT NULL,
    reset_day integer,
    rollover_mode character varying(255) DEFAULT 'reset'::character varying NOT NULL,
    rollover_pct integer,
    rollover_cap_units bigint,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    starts_at timestamp(0) without time zone,
    expires_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: global_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.global_settings (
    id integer DEFAULT 1 NOT NULL,
    daily_max_spend_usd numeric,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: group_member_extra_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_member_extra_models (
    id uuid NOT NULL,
    group_member_id uuid NOT NULL,
    model_id uuid CONSTRAINT group_member_extra_models_model_alias_id_not_null NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_members (
    id uuid NOT NULL,
    user_id uuid NOT NULL,
    group_id uuid NOT NULL,
    extra_concurrency integer,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    extra_rpm integer
);


--
-- Name: group_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.group_models (
    id uuid NOT NULL,
    group_id uuid NOT NULL,
    model_id uuid CONSTRAINT group_models_model_alias_id_not_null NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.groups (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    default_concurrency_limit integer DEFAULT 5 NOT NULL,
    default_rpm_limit integer DEFAULT 60 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    default_subscription_id uuid
);


--
-- Name: model_providers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.model_providers (
    id uuid NOT NULL,
    model_id uuid CONSTRAINT model_providers_model_alias_id_not_null NOT NULL,
    provider_model character varying(255) NOT NULL,
    priority integer,
    enabled boolean DEFAULT true NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    credential_id uuid NOT NULL,
    exclusive_to_group_member_id uuid,
    exclusive_to_group_id uuid,
    sticky_ttl_ms integer,
    input_cost_per_million numeric(12,6),
    output_cost_per_million numeric(12,6),
    cache_cost_per_million numeric(12,6),
    exclusive_to_service_id uuid,
    cache_control_enabled boolean DEFAULT false NOT NULL,
    extra_body jsonb DEFAULT '{}'::jsonb NOT NULL,
    omit_body_fields character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL,
    omit_headers character varying(255)[] DEFAULT ARRAY[]::character varying[] NOT NULL
);


--
-- Name: models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.models (
    id uuid CONSTRAINT model_aliases_id_not_null NOT NULL,
    name character varying(255) CONSTRAINT model_aliases_name_not_null NOT NULL,
    context_window integer CONSTRAINT model_aliases_context_window_not_null NOT NULL,
    inserted_at timestamp(0) without time zone CONSTRAINT model_aliases_inserted_at_not_null NOT NULL,
    updated_at timestamp(0) without time zone CONSTRAINT model_aliases_updated_at_not_null NOT NULL,
    guard_rails text,
    prompt_cache_enabled boolean DEFAULT false CONSTRAINT model_aliases_prompt_cache_enabled_not_null NOT NULL,
    lazy_cleanup_enabled boolean DEFAULT false CONSTRAINT model_aliases_lazy_cleanup_enabled_not_null NOT NULL,
    model_type character varying(255) DEFAULT 'llm'::character varying CONSTRAINT model_aliases_model_type_not_null NOT NULL,
    pinned boolean DEFAULT false CONSTRAINT model_aliases_pinned_not_null NOT NULL,
    market_input_price_per_1m numeric(12,6),
    market_output_price_per_1m numeric(12,6),
    market_cache_price_per_1m numeric(12,6),
    CONSTRAINT model_aliases_model_type_check CHECK (((model_type)::text = ANY (ARRAY[('llm'::character varying)::text, ('embedding'::character varying)::text])))
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
    group_id uuid NOT NULL
);


--
-- Name: provider_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.provider_credentials (
    id uuid NOT NULL,
    provider_id uuid NOT NULL,
    api_key_encrypted character varying(255) NOT NULL,
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    name character varying(255),
    error_reason character varying(255),
    error_at timestamp(0) without time zone,
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
    status character varying(255) DEFAULT 'active'::character varying NOT NULL,
    key character varying(255),
    source character varying(255) DEFAULT 'custom'::character varying NOT NULL,
    dialect character varying(255) DEFAULT 'openai'::character varying NOT NULL,
    capabilities character varying(255)[] DEFAULT ARRAY['llm'::character varying] NOT NULL,
    doc_url character varying(255),
    logo_url character varying(255),
    max_rpm integer,
    max_concurrent integer,
    max_concurrent_per_user integer,
    receive_timeout_ms integer
);


--
-- Name: request_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs (
    id uuid NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 NOT NULL,
    cache_creation_tokens integer DEFAULT 0 NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
)
PARTITION BY RANGE (inserted_at);


--
-- Name: request_logs_2026_07_26; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_07_26 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_07_27; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_07_27 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_08_05; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_08_05 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_08_27; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_08_27 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_08_28; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_08_28 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_08_29; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_08_29 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_08_30; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_08_30 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_08_31; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_08_31 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_01; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_01 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_02; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_02 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_03; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_03 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_04; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_04 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_05; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_05 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_06; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_06 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_07; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_07 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_08; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_08 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_09; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_09 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_10; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_10 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_11; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_11 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_12; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_12 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_13; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_13 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_14; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_14 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_15; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_15 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_16; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_16 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_17; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_17 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_18; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_18 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_2026_09_19; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_2026_09_19 (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_default; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_default (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
    provider_id uuid,
    model_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL,
    credit_subscription_id uuid,
    session_id character varying(255)
);


--
-- Name: request_logs_proto; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_logs_proto (
    id uuid CONSTRAINT request_logs_id_not_null NOT NULL,
    group_member_id uuid,
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
    error_reason character varying(255),
    client_agent character varying(255),
    provider_key_prefix character varying(255),
    cache_read_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_read_tokens_not_null NOT NULL,
    cache_creation_tokens integer DEFAULT 0 CONSTRAINT request_logs_cache_creation_tokens_not_null NOT NULL,
    request_type character varying(255) DEFAULT 'chat'::character varying CONSTRAINT request_logs_request_type_not_null NOT NULL,
    error_message character varying(255),
    credential_id uuid,
    service_id uuid,
    subject_type character varying(255) DEFAULT 'user'::character varying CONSTRAINT request_logs_subject_type_not_null NOT NULL
);


--
-- Name: request_metrics_hourly; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.request_metrics_hourly (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    day date NOT NULL,
    hour_utc timestamp without time zone NOT NULL,
    group_member_id uuid,
    model_id uuid,
    provider_id uuid,
    request_count bigint DEFAULT 0 NOT NULL,
    error_count bigint DEFAULT 0 NOT NULL,
    prompt_tokens bigint DEFAULT 0 NOT NULL,
    completion_tokens bigint DEFAULT 0 NOT NULL,
    cache_read_tokens bigint DEFAULT 0 NOT NULL,
    cache_creation_tokens bigint DEFAULT 0 NOT NULL,
    cost_micro bigint DEFAULT 0 NOT NULL,
    total_latency_ms bigint DEFAULT 0 NOT NULL,
    latency_count bigint DEFAULT 0 NOT NULL,
    inserted_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: service_models; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_models (
    id uuid CONSTRAINT service_model_aliases_id_not_null NOT NULL,
    service_id uuid CONSTRAINT service_model_aliases_service_id_not_null NOT NULL,
    model_id uuid CONSTRAINT service_model_aliases_model_alias_id_not_null NOT NULL,
    inserted_at timestamp(0) without time zone CONSTRAINT service_model_aliases_inserted_at_not_null NOT NULL,
    updated_at timestamp(0) without time zone CONSTRAINT service_model_aliases_updated_at_not_null NOT NULL
);


--
-- Name: service_supervisors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_supervisors (
    id uuid NOT NULL,
    service_id uuid NOT NULL,
    user_id uuid NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.services (
    id uuid NOT NULL,
    name character varying(255) NOT NULL,
    concurrency_limit integer DEFAULT 5 NOT NULL,
    rpm_limit integer DEFAULT 60 NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    group_id uuid,
    subscription_id uuid
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
    avatar_url character varying(255),
    timezone character varying(255) DEFAULT 'Etc/UTC'::character varying NOT NULL
);


--
-- Name: request_logs_2026_07_26; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_07_26 FOR VALUES FROM ('2026-07-26 00:00:00') TO ('2026-07-27 00:00:00');


--
-- Name: request_logs_2026_07_27; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_07_27 FOR VALUES FROM ('2026-07-27 00:00:00') TO ('2026-07-28 00:00:00');


--
-- Name: request_logs_2026_08_05; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_08_05 FOR VALUES FROM ('2026-08-05 00:00:00') TO ('2026-08-06 00:00:00');


--
-- Name: request_logs_2026_08_27; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_08_27 FOR VALUES FROM ('2026-08-27 00:00:00') TO ('2026-08-28 00:00:00');


--
-- Name: request_logs_2026_08_28; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_08_28 FOR VALUES FROM ('2026-08-28 00:00:00') TO ('2026-08-29 00:00:00');


--
-- Name: request_logs_2026_08_29; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_08_29 FOR VALUES FROM ('2026-08-29 00:00:00') TO ('2026-08-30 00:00:00');


--
-- Name: request_logs_2026_08_30; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_08_30 FOR VALUES FROM ('2026-08-30 00:00:00') TO ('2026-08-31 00:00:00');


--
-- Name: request_logs_2026_08_31; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_08_31 FOR VALUES FROM ('2026-08-31 00:00:00') TO ('2026-09-01 00:00:00');


--
-- Name: request_logs_2026_09_01; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_01 FOR VALUES FROM ('2026-09-01 00:00:00') TO ('2026-09-02 00:00:00');


--
-- Name: request_logs_2026_09_02; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_02 FOR VALUES FROM ('2026-09-02 00:00:00') TO ('2026-09-03 00:00:00');


--
-- Name: request_logs_2026_09_03; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_03 FOR VALUES FROM ('2026-09-03 00:00:00') TO ('2026-09-04 00:00:00');


--
-- Name: request_logs_2026_09_04; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_04 FOR VALUES FROM ('2026-09-04 00:00:00') TO ('2026-09-05 00:00:00');


--
-- Name: request_logs_2026_09_05; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_05 FOR VALUES FROM ('2026-09-05 00:00:00') TO ('2026-09-06 00:00:00');


--
-- Name: request_logs_2026_09_06; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_06 FOR VALUES FROM ('2026-09-06 00:00:00') TO ('2026-09-07 00:00:00');


--
-- Name: request_logs_2026_09_07; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_07 FOR VALUES FROM ('2026-09-07 00:00:00') TO ('2026-09-08 00:00:00');


--
-- Name: request_logs_2026_09_08; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_08 FOR VALUES FROM ('2026-09-08 00:00:00') TO ('2026-09-09 00:00:00');


--
-- Name: request_logs_2026_09_09; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_09 FOR VALUES FROM ('2026-09-09 00:00:00') TO ('2026-09-10 00:00:00');


--
-- Name: request_logs_2026_09_10; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_10 FOR VALUES FROM ('2026-09-10 00:00:00') TO ('2026-09-11 00:00:00');


--
-- Name: request_logs_2026_09_11; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_11 FOR VALUES FROM ('2026-09-11 00:00:00') TO ('2026-09-12 00:00:00');


--
-- Name: request_logs_2026_09_12; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_12 FOR VALUES FROM ('2026-09-12 00:00:00') TO ('2026-09-13 00:00:00');


--
-- Name: request_logs_2026_09_13; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_13 FOR VALUES FROM ('2026-09-13 00:00:00') TO ('2026-09-14 00:00:00');


--
-- Name: request_logs_2026_09_14; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_14 FOR VALUES FROM ('2026-09-14 00:00:00') TO ('2026-09-15 00:00:00');


--
-- Name: request_logs_2026_09_15; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_15 FOR VALUES FROM ('2026-09-15 00:00:00') TO ('2026-09-16 00:00:00');


--
-- Name: request_logs_2026_09_16; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_16 FOR VALUES FROM ('2026-09-16 00:00:00') TO ('2026-09-17 00:00:00');


--
-- Name: request_logs_2026_09_17; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_17 FOR VALUES FROM ('2026-09-17 00:00:00') TO ('2026-09-18 00:00:00');


--
-- Name: request_logs_2026_09_18; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_18 FOR VALUES FROM ('2026-09-18 00:00:00') TO ('2026-09-19 00:00:00');


--
-- Name: request_logs_2026_09_19; Type: TABLE ATTACH; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs ATTACH PARTITION public.request_logs_2026_09_19 FOR VALUES FROM ('2026-09-19 00:00:00') TO ('2026-09-20 00:00:00');


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
-- Name: budget_exemptions budget_exemptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_exemptions
    ADD CONSTRAINT budget_exemptions_pkey PRIMARY KEY (id);


--
-- Name: catalog_providers catalog_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_providers
    ADD CONSTRAINT catalog_providers_pkey PRIMARY KEY (key);


--
-- Name: catalog_sync_state catalog_sync_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_sync_state
    ADD CONSTRAINT catalog_sync_state_pkey PRIMARY KEY (id);


--
-- Name: credit_subscriptions credit_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_subscriptions
    ADD CONSTRAINT credit_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: global_settings global_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.global_settings
    ADD CONSTRAINT global_settings_pkey PRIMARY KEY (id);


--
-- Name: group_member_extra_models group_member_extra_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_member_extra_models
    ADD CONSTRAINT group_member_extra_models_pkey PRIMARY KEY (id);


--
-- Name: group_members group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_pkey PRIMARY KEY (id);


--
-- Name: group_models group_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_models
    ADD CONSTRAINT group_models_pkey PRIMARY KEY (id);


--
-- Name: groups groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT groups_pkey PRIMARY KEY (id);


--
-- Name: model_providers model_providers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_pkey PRIMARY KEY (id);


--
-- Name: models models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.models
    ADD CONSTRAINT models_pkey PRIMARY KEY (id);


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
-- Name: request_logs_2026_07_27 request_logs_2026_07_27_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_07_27
    ADD CONSTRAINT request_logs_2026_07_27_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_08_05 request_logs_2026_08_05_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_08_05
    ADD CONSTRAINT request_logs_2026_08_05_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_08_27 request_logs_2026_08_27_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_08_27
    ADD CONSTRAINT request_logs_2026_08_27_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_08_28 request_logs_2026_08_28_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_08_28
    ADD CONSTRAINT request_logs_2026_08_28_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_08_29 request_logs_2026_08_29_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_08_29
    ADD CONSTRAINT request_logs_2026_08_29_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_08_30 request_logs_2026_08_30_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_08_30
    ADD CONSTRAINT request_logs_2026_08_30_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_08_31 request_logs_2026_08_31_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_08_31
    ADD CONSTRAINT request_logs_2026_08_31_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_01 request_logs_2026_09_01_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_01
    ADD CONSTRAINT request_logs_2026_09_01_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_02 request_logs_2026_09_02_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_02
    ADD CONSTRAINT request_logs_2026_09_02_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_03 request_logs_2026_09_03_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_03
    ADD CONSTRAINT request_logs_2026_09_03_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_04 request_logs_2026_09_04_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_04
    ADD CONSTRAINT request_logs_2026_09_04_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_05 request_logs_2026_09_05_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_05
    ADD CONSTRAINT request_logs_2026_09_05_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_06 request_logs_2026_09_06_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_06
    ADD CONSTRAINT request_logs_2026_09_06_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_07 request_logs_2026_09_07_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_07
    ADD CONSTRAINT request_logs_2026_09_07_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_08 request_logs_2026_09_08_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_08
    ADD CONSTRAINT request_logs_2026_09_08_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_09 request_logs_2026_09_09_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_09
    ADD CONSTRAINT request_logs_2026_09_09_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_10 request_logs_2026_09_10_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_10
    ADD CONSTRAINT request_logs_2026_09_10_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_11 request_logs_2026_09_11_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_11
    ADD CONSTRAINT request_logs_2026_09_11_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_12 request_logs_2026_09_12_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_12
    ADD CONSTRAINT request_logs_2026_09_12_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_13 request_logs_2026_09_13_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_13
    ADD CONSTRAINT request_logs_2026_09_13_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_14 request_logs_2026_09_14_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_14
    ADD CONSTRAINT request_logs_2026_09_14_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_15 request_logs_2026_09_15_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_15
    ADD CONSTRAINT request_logs_2026_09_15_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_16 request_logs_2026_09_16_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_16
    ADD CONSTRAINT request_logs_2026_09_16_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_17 request_logs_2026_09_17_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_17
    ADD CONSTRAINT request_logs_2026_09_17_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_18 request_logs_2026_09_18_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_18
    ADD CONSTRAINT request_logs_2026_09_18_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_2026_09_19 request_logs_2026_09_19_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_2026_09_19
    ADD CONSTRAINT request_logs_2026_09_19_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_default request_logs_default_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_default
    ADD CONSTRAINT request_logs_default_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_logs_proto request_logs_proto_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_logs_proto
    ADD CONSTRAINT request_logs_proto_pkey PRIMARY KEY (id, inserted_at);


--
-- Name: request_metrics_hourly request_metrics_hourly_bucket_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_metrics_hourly
    ADD CONSTRAINT request_metrics_hourly_bucket_key UNIQUE NULLS NOT DISTINCT (day, hour_utc, group_member_id, model_id, provider_id);


--
-- Name: request_metrics_hourly request_metrics_hourly_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.request_metrics_hourly
    ADD CONSTRAINT request_metrics_hourly_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: service_models service_models_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_models
    ADD CONSTRAINT service_models_pkey PRIMARY KEY (id);


--
-- Name: service_supervisors service_supervisors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_supervisors
    ADD CONSTRAINT service_supervisors_pkey PRIMARY KEY (id);


--
-- Name: services services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: api_keys_group_member_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_keys_group_member_active_index ON public.api_keys USING btree (group_member_id) WHERE (((subject_type)::text = 'member'::text) AND ((status)::text = 'active'::text));


--
-- Name: api_keys_key_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_keys_key_hash_index ON public.api_keys USING btree (key_hash);


--
-- Name: api_keys_service_id_active_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_keys_service_id_active_index ON public.api_keys USING btree (service_id) WHERE (((subject_type)::text = 'service'::text) AND ((status)::text = 'active'::text));


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
-- Name: budget_exemptions_global_daily_service_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX budget_exemptions_global_daily_service_unique ON public.budget_exemptions USING btree (service_id) WHERE (((scope)::text = 'global_daily'::text) AND ((subject_type)::text = 'service'::text) AND (service_id IS NOT NULL));


--
-- Name: budget_exemptions_global_daily_user_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX budget_exemptions_global_daily_user_unique ON public.budget_exemptions USING btree (user_id) WHERE (((scope)::text = 'global_daily'::text) AND ((subject_type)::text = 'user'::text) AND (user_id IS NOT NULL));


--
-- Name: budget_exemptions_scope_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX budget_exemptions_scope_index ON public.budget_exemptions USING btree (scope);


--
-- Name: catalog_providers_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX catalog_providers_status_index ON public.catalog_providers USING btree (status);


--
-- Name: credit_subscriptions_status_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX credit_subscriptions_status_index ON public.credit_subscriptions USING btree (status);


--
-- Name: credit_subscriptions_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX credit_subscriptions_user_id_index ON public.credit_subscriptions USING btree (user_id);


--
-- Name: group_member_extra_models_group_member_id_model_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX group_member_extra_models_group_member_id_model_id_index ON public.group_member_extra_models USING btree (group_member_id, model_id);


--
-- Name: group_members_group_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX group_members_group_id_index ON public.group_members USING btree (group_id);


--
-- Name: group_members_user_group_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX group_members_user_group_unique_index ON public.group_members USING btree (user_id, group_id);


--
-- Name: group_models_group_id_model_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX group_models_group_id_model_id_index ON public.group_models USING btree (group_id, model_id);


--
-- Name: model_providers_global_credential_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_providers_global_credential_unique_index ON public.model_providers USING btree (credential_id, model_id) WHERE ((exclusive_to_group_member_id IS NULL) AND (exclusive_to_group_id IS NULL) AND (exclusive_to_service_id IS NULL));


--
-- Name: model_providers_group_exclusive_target_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_providers_group_exclusive_target_unique_index ON public.model_providers USING btree (model_id, exclusive_to_group_id) WHERE (exclusive_to_group_id IS NOT NULL);


--
-- Name: model_providers_member_exclusive_target_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_providers_member_exclusive_target_unique_index ON public.model_providers USING btree (model_id, exclusive_to_group_member_id) WHERE (exclusive_to_group_member_id IS NOT NULL);


--
-- Name: model_providers_model_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX model_providers_model_id_index ON public.model_providers USING btree (model_id);


--
-- Name: model_providers_service_exclusive_target_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX model_providers_service_exclusive_target_unique_index ON public.model_providers USING btree (model_id, exclusive_to_service_id) WHERE (exclusive_to_service_id IS NOT NULL);


--
-- Name: models_name_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX models_name_index ON public.models USING btree (name);


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
-- Name: observability_destinations_group_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX observability_destinations_group_id_index ON public.observability_destinations USING btree (group_id);


--
-- Name: provider_credentials_provider_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX provider_credentials_provider_id_index ON public.provider_credentials USING btree (provider_id);


--
-- Name: providers_builtin_key_unique_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX providers_builtin_key_unique_index ON public.providers USING btree (key) WHERE (key IS NOT NULL);


--
-- Name: request_logs_agent_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_agent_type_idx ON ONLY public.request_logs USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_07_26_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_agent_type_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_credential_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_credential_inserted_idx ON ONLY public.request_logs USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_07_26_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_credential_id_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_credential_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_credential_name_idx ON ONLY public.request_logs USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_07_26_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_credential_name_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_member_inserted_covering_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_member_inserted_covering_idx ON ONLY public.request_logs USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_07_26_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_07_26 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_inserted_idx ON ONLY public.request_logs USING btree (inserted_at);


--
-- Name: request_logs_2026_07_26_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (inserted_at);


--
-- Name: request_logs_model_inserted_desc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_model_inserted_desc_idx ON ONLY public.request_logs USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_07_26_model_id_inserted_at_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_model_id_inserted_at_idx1 ON public.request_logs_2026_07_26 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_model_provider_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_model_provider_id_index ON ONLY public.request_logs USING btree (model_provider_id);


--
-- Name: request_logs_2026_07_26_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_model_provider_id_idx ON public.request_logs_2026_07_26 USING btree (model_provider_id);


--
-- Name: request_logs_provider_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_provider_inserted_idx ON ONLY public.request_logs USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_07_26_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_provider_id_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_service_inserted_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_service_inserted_idx ON ONLY public.request_logs USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_07_26_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_service_id_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_session_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_session_id_idx ON ONLY public.request_logs USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_07_26_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_session_id_inserted_at_idx ON public.request_logs_2026_07_26 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_errors_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_errors_idx ON ONLY public.request_logs USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_07_26_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_26_status_code_idx ON public.request_logs_2026_07_26 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_07_27_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_agent_type_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_07_27_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_credential_id_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_07_27_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_credential_name_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_07_27_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_07_27 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_07_27_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (inserted_at);


--
-- Name: request_logs_2026_07_27_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_model_id_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_07_27_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_model_provider_id_idx ON public.request_logs_2026_07_27 USING btree (model_provider_id);


--
-- Name: request_logs_2026_07_27_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_provider_id_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_07_27_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_service_id_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_07_27_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_session_id_inserted_at_idx ON public.request_logs_2026_07_27 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_07_27_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_07_27_status_code_idx ON public.request_logs_2026_07_27 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_08_05_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_agent_type_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_08_05_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_credential_id_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_08_05_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_credential_name_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_08_05_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_08_05 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_08_05_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (inserted_at);


--
-- Name: request_logs_2026_08_05_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_model_id_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_05_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_model_provider_id_idx ON public.request_logs_2026_08_05 USING btree (model_provider_id);


--
-- Name: request_logs_2026_08_05_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_provider_id_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_08_05_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_service_id_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_05_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_session_id_inserted_at_idx ON public.request_logs_2026_08_05 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_08_05_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_05_status_code_idx ON public.request_logs_2026_08_05 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_08_27_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_agent_type_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_08_27_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_credential_id_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_08_27_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_credential_name_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_08_27_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_08_27 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_08_27_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (inserted_at);


--
-- Name: request_logs_2026_08_27_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_model_id_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_27_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_model_provider_id_idx ON public.request_logs_2026_08_27 USING btree (model_provider_id);


--
-- Name: request_logs_2026_08_27_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_provider_id_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_08_27_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_service_id_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_27_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_session_id_inserted_at_idx ON public.request_logs_2026_08_27 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_08_27_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_27_status_code_idx ON public.request_logs_2026_08_27 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_08_28_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_agent_type_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_08_28_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_credential_id_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_08_28_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_credential_name_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_08_28_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_08_28 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_08_28_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (inserted_at);


--
-- Name: request_logs_2026_08_28_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_model_id_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_28_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_model_provider_id_idx ON public.request_logs_2026_08_28 USING btree (model_provider_id);


--
-- Name: request_logs_2026_08_28_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_provider_id_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_08_28_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_service_id_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_28_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_session_id_inserted_at_idx ON public.request_logs_2026_08_28 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_08_28_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_28_status_code_idx ON public.request_logs_2026_08_28 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_08_29_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_agent_type_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_08_29_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_credential_id_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_08_29_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_credential_name_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_08_29_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_08_29 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_08_29_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (inserted_at);


--
-- Name: request_logs_2026_08_29_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_model_id_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_29_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_model_provider_id_idx ON public.request_logs_2026_08_29 USING btree (model_provider_id);


--
-- Name: request_logs_2026_08_29_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_provider_id_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_08_29_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_service_id_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_29_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_session_id_inserted_at_idx ON public.request_logs_2026_08_29 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_08_29_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_29_status_code_idx ON public.request_logs_2026_08_29 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_08_30_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_agent_type_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_08_30_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_credential_id_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_08_30_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_credential_name_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_08_30_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_08_30 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_08_30_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (inserted_at);


--
-- Name: request_logs_2026_08_30_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_model_id_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_30_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_model_provider_id_idx ON public.request_logs_2026_08_30 USING btree (model_provider_id);


--
-- Name: request_logs_2026_08_30_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_provider_id_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_08_30_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_service_id_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_30_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_session_id_inserted_at_idx ON public.request_logs_2026_08_30 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_08_30_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_30_status_code_idx ON public.request_logs_2026_08_30 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_08_31_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_agent_type_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_08_31_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_credential_id_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_08_31_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_credential_name_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_08_31_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_08_31 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_08_31_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (inserted_at);


--
-- Name: request_logs_2026_08_31_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_model_id_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_31_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_model_provider_id_idx ON public.request_logs_2026_08_31 USING btree (model_provider_id);


--
-- Name: request_logs_2026_08_31_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_provider_id_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_08_31_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_service_id_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_08_31_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_session_id_inserted_at_idx ON public.request_logs_2026_08_31 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_08_31_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_08_31_status_code_idx ON public.request_logs_2026_08_31 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_01_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_agent_type_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_01_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_credential_id_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_01_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_credential_name_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_01_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_01 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_01_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_01_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_model_id_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_01_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_model_provider_id_idx ON public.request_logs_2026_09_01 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_01_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_provider_id_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_01_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_service_id_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_01_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_session_id_inserted_at_idx ON public.request_logs_2026_09_01 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_01_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_01_status_code_idx ON public.request_logs_2026_09_01 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_02_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_agent_type_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_02_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_credential_id_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_02_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_credential_name_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_02_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_02 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_02_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_02_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_model_id_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_02_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_model_provider_id_idx ON public.request_logs_2026_09_02 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_02_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_provider_id_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_02_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_service_id_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_02_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_session_id_inserted_at_idx ON public.request_logs_2026_09_02 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_02_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_02_status_code_idx ON public.request_logs_2026_09_02 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_03_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_agent_type_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_03_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_credential_id_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_03_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_credential_name_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_03_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_03 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_03_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_03_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_model_id_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_03_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_model_provider_id_idx ON public.request_logs_2026_09_03 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_03_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_provider_id_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_03_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_service_id_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_03_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_session_id_inserted_at_idx ON public.request_logs_2026_09_03 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_03_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_03_status_code_idx ON public.request_logs_2026_09_03 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_04_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_agent_type_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_04_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_credential_id_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_04_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_credential_name_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_04_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_04 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_04_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_04_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_model_id_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_04_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_model_provider_id_idx ON public.request_logs_2026_09_04 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_04_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_provider_id_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_04_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_service_id_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_04_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_session_id_inserted_at_idx ON public.request_logs_2026_09_04 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_04_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_04_status_code_idx ON public.request_logs_2026_09_04 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_05_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_agent_type_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_05_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_credential_id_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_05_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_credential_name_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_05_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_05 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_05_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_05_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_model_id_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_05_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_model_provider_id_idx ON public.request_logs_2026_09_05 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_05_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_provider_id_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_05_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_service_id_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_05_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_session_id_inserted_at_idx ON public.request_logs_2026_09_05 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_05_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_05_status_code_idx ON public.request_logs_2026_09_05 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_06_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_agent_type_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_06_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_credential_id_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_06_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_credential_name_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_06_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_06 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_06_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_06_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_model_id_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_06_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_model_provider_id_idx ON public.request_logs_2026_09_06 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_06_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_provider_id_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_06_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_service_id_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_06_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_session_id_inserted_at_idx ON public.request_logs_2026_09_06 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_06_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_06_status_code_idx ON public.request_logs_2026_09_06 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_07_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_agent_type_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_07_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_credential_id_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_07_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_credential_name_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_07_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_07 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_07_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_07_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_model_id_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_07_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_model_provider_id_idx ON public.request_logs_2026_09_07 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_07_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_provider_id_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_07_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_service_id_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_07_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_session_id_inserted_at_idx ON public.request_logs_2026_09_07 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_07_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_07_status_code_idx ON public.request_logs_2026_09_07 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_08_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_agent_type_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_08_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_credential_id_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_08_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_credential_name_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_08_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_08 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_08_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_08_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_model_id_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_08_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_model_provider_id_idx ON public.request_logs_2026_09_08 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_08_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_provider_id_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_08_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_service_id_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_08_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_session_id_inserted_at_idx ON public.request_logs_2026_09_08 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_08_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_08_status_code_idx ON public.request_logs_2026_09_08 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_09_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_agent_type_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_09_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_credential_id_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_09_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_credential_name_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_09_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_09 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_09_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_09_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_model_id_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_09_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_model_provider_id_idx ON public.request_logs_2026_09_09 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_09_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_provider_id_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_09_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_service_id_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_09_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_session_id_inserted_at_idx ON public.request_logs_2026_09_09 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_09_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_09_status_code_idx ON public.request_logs_2026_09_09 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_10_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_agent_type_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_10_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_credential_id_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_10_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_credential_name_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_10_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_10 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_10_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_10_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_model_id_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_10_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_model_provider_id_idx ON public.request_logs_2026_09_10 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_10_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_provider_id_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_10_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_service_id_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_10_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_session_id_inserted_at_idx ON public.request_logs_2026_09_10 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_10_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_10_status_code_idx ON public.request_logs_2026_09_10 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_11_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_agent_type_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_11_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_credential_id_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_11_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_credential_name_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_11_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_11 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_11_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_11_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_model_id_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_11_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_model_provider_id_idx ON public.request_logs_2026_09_11 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_11_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_provider_id_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_11_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_service_id_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_11_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_session_id_inserted_at_idx ON public.request_logs_2026_09_11 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_11_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_11_status_code_idx ON public.request_logs_2026_09_11 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_12_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_agent_type_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_12_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_credential_id_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_12_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_credential_name_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_12_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_12 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_12_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_12_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_model_id_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_12_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_model_provider_id_idx ON public.request_logs_2026_09_12 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_12_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_provider_id_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_12_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_service_id_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_12_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_session_id_inserted_at_idx ON public.request_logs_2026_09_12 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_12_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_12_status_code_idx ON public.request_logs_2026_09_12 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_13_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_agent_type_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_13_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_credential_id_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_13_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_credential_name_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_13_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_13 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_13_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_13_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_model_id_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_13_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_model_provider_id_idx ON public.request_logs_2026_09_13 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_13_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_provider_id_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_13_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_service_id_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_13_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_session_id_inserted_at_idx ON public.request_logs_2026_09_13 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_13_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_13_status_code_idx ON public.request_logs_2026_09_13 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_14_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_agent_type_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_14_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_credential_id_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_14_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_credential_name_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_14_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_14 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_14_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_14_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_model_id_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_14_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_model_provider_id_idx ON public.request_logs_2026_09_14 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_14_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_provider_id_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_14_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_service_id_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_14_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_session_id_inserted_at_idx ON public.request_logs_2026_09_14 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_14_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_14_status_code_idx ON public.request_logs_2026_09_14 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_15_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_agent_type_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_15_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_credential_id_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_15_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_credential_name_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_15_group_member_id_inserted_at_id_provi_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_group_member_id_inserted_at_id_provi_id ON public.request_logs_2026_09_15 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_15_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_15_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_model_id_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_15_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_model_provider_id_idx ON public.request_logs_2026_09_15 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_15_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_provider_id_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_15_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_service_id_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_15_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_session_id_inserted_at_idx ON public.request_logs_2026_09_15 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_15_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_15_status_code_idx ON public.request_logs_2026_09_15 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_16_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_agent_type_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_16_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_credential_id_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_16_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_credential_name_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_16_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_16_model_alias_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_model_alias_id_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_16_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_model_provider_id_idx ON public.request_logs_2026_09_16 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_16_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_provider_id_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_16_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_service_id_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_16_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_session_id_inserted_at_idx ON public.request_logs_2026_09_16 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_16_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_status_code_idx ON public.request_logs_2026_09_16 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_16_team_member_id_inserted_at_id_provi_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_16_team_member_id_inserted_at_id_provi_idx ON public.request_logs_2026_09_16 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_17_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_agent_type_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_17_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_credential_id_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_17_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_credential_name_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_17_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_17_model_alias_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_model_alias_id_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_17_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_model_provider_id_idx ON public.request_logs_2026_09_17 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_17_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_provider_id_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_17_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_service_id_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_17_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_session_id_inserted_at_idx ON public.request_logs_2026_09_17 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_17_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_status_code_idx ON public.request_logs_2026_09_17 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_17_team_member_id_inserted_at_id_provi_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_17_team_member_id_inserted_at_id_provi_idx ON public.request_logs_2026_09_17 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_18_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_agent_type_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_18_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_credential_id_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_18_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_credential_name_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_18_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_18_model_alias_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_model_alias_id_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_18_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_model_provider_id_idx ON public.request_logs_2026_09_18 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_18_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_provider_id_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_18_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_service_id_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_18_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_session_id_inserted_at_idx ON public.request_logs_2026_09_18 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_18_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_status_code_idx ON public.request_logs_2026_09_18 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_18_team_member_id_inserted_at_id_provi_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_18_team_member_id_inserted_at_id_provi_idx ON public.request_logs_2026_09_18 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_2026_09_19_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_agent_type_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_2026_09_19_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_credential_id_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (credential_id, inserted_at);


--
-- Name: request_logs_2026_09_19_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_credential_name_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (credential_name, inserted_at);


--
-- Name: request_logs_2026_09_19_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (inserted_at);


--
-- Name: request_logs_2026_09_19_model_alias_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_model_alias_id_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_19_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_model_provider_id_idx ON public.request_logs_2026_09_19 USING btree (model_provider_id);


--
-- Name: request_logs_2026_09_19_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_provider_id_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (provider_id, inserted_at);


--
-- Name: request_logs_2026_09_19_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_service_id_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_2026_09_19_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_session_id_inserted_at_idx ON public.request_logs_2026_09_19 USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_2026_09_19_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_status_code_idx ON public.request_logs_2026_09_19 USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_2026_09_19_team_member_id_inserted_at_id_provi_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_2026_09_19_team_member_id_inserted_at_id_provi_idx ON public.request_logs_2026_09_19 USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_default_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_agent_type_inserted_at_idx ON public.request_logs_default USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_default_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_credential_id_inserted_at_idx ON public.request_logs_default USING btree (credential_id, inserted_at);


--
-- Name: request_logs_default_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_credential_name_inserted_at_idx ON public.request_logs_default USING btree (credential_name, inserted_at);


--
-- Name: request_logs_default_group_member_id_inserted_at_id_provider_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_group_member_id_inserted_at_id_provider_id ON public.request_logs_default USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_default_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_inserted_at_idx ON public.request_logs_default USING btree (inserted_at);


--
-- Name: request_logs_default_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_model_id_inserted_at_idx ON public.request_logs_default USING btree (model_id, inserted_at DESC);


--
-- Name: request_logs_default_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_model_provider_id_idx ON public.request_logs_default USING btree (model_provider_id);


--
-- Name: request_logs_default_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_provider_id_inserted_at_idx ON public.request_logs_default USING btree (provider_id, inserted_at);


--
-- Name: request_logs_default_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_service_id_inserted_at_idx ON public.request_logs_default USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_default_session_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_session_id_inserted_at_idx ON public.request_logs_default USING btree (session_id, inserted_at) WHERE (session_id IS NOT NULL);


--
-- Name: request_logs_default_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_default_status_code_idx ON public.request_logs_default USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_logs_proto_agent_type_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_agent_type_inserted_at_idx ON public.request_logs_proto USING btree (agent_type, inserted_at) WHERE (agent_type IS NOT NULL);


--
-- Name: request_logs_proto_credential_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_credential_id_inserted_at_idx ON public.request_logs_proto USING btree (credential_id, inserted_at);


--
-- Name: request_logs_proto_credential_name_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_credential_name_inserted_at_idx ON public.request_logs_proto USING btree (credential_name, inserted_at);


--
-- Name: request_logs_proto_group_member_id_inserted_at_id_provider_c_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_group_member_id_inserted_at_id_provider_c_id ON public.request_logs_proto USING btree (group_member_id, inserted_at) INCLUDE (id, provider_cost_usd, prompt_tokens, completion_tokens, cache_read_tokens, cache_creation_tokens);


--
-- Name: request_logs_proto_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_inserted_at_idx ON public.request_logs_proto USING btree (inserted_at);


--
-- Name: request_logs_proto_model_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_model_id_inserted_at_idx ON public.request_logs_proto USING btree (model_alias_id, inserted_at DESC);


--
-- Name: request_logs_proto_model_provider_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_model_provider_id_idx ON public.request_logs_proto USING btree (model_provider_id);


--
-- Name: request_logs_proto_provider_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_provider_id_inserted_at_idx ON public.request_logs_proto USING btree (provider_id, inserted_at);


--
-- Name: request_logs_proto_service_id_inserted_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_service_id_inserted_at_idx ON public.request_logs_proto USING btree (service_id, inserted_at DESC);


--
-- Name: request_logs_proto_status_code_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_logs_proto_status_code_idx ON public.request_logs_proto USING btree (status_code) WHERE (status_code >= 400);


--
-- Name: request_metrics_hourly_hour_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_metrics_hourly_hour_idx ON public.request_metrics_hourly USING btree (day, hour_utc);


--
-- Name: request_metrics_hourly_member_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_metrics_hourly_member_idx ON public.request_metrics_hourly USING btree (day, hour_utc, group_member_id);


--
-- Name: request_metrics_hourly_model_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_metrics_hourly_model_idx ON public.request_metrics_hourly USING btree (day, hour_utc, model_id);


--
-- Name: request_metrics_hourly_provider_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX request_metrics_hourly_provider_idx ON public.request_metrics_hourly USING btree (day, hour_utc, provider_id);


--
-- Name: service_models_service_id_model_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX service_models_service_id_model_id_index ON public.service_models USING btree (service_id, model_id);


--
-- Name: service_supervisors_service_id_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX service_supervisors_service_id_user_id_index ON public.service_supervisors USING btree (service_id, user_id);


--
-- Name: service_supervisors_user_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX service_supervisors_user_id_index ON public.service_supervisors USING btree (user_id);


--
-- Name: services_subscription_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX services_subscription_id_index ON public.services USING btree (subscription_id);


--
-- Name: users_email_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_email_index ON public.users USING btree (email);


--
-- Name: users_google_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_google_id_index ON public.users USING btree (google_id);


--
-- Name: request_logs_2026_07_26_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_07_26_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_07_26_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_07_26_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_07_26_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_07_26_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_07_26_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_model_id_inserted_at_idx1; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_07_26_model_id_inserted_at_idx1;


--
-- Name: request_logs_2026_07_26_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_07_26_model_provider_id_idx;


--
-- Name: request_logs_2026_07_26_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_07_26_pkey;


--
-- Name: request_logs_2026_07_26_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_07_26_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_07_26_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_07_26_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_26_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_07_26_status_code_idx;


--
-- Name: request_logs_2026_07_27_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_07_27_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_07_27_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_07_27_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_07_27_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_07_27_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_07_27_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_07_27_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_07_27_model_provider_id_idx;


--
-- Name: request_logs_2026_07_27_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_07_27_pkey;


--
-- Name: request_logs_2026_07_27_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_07_27_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_07_27_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_07_27_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_07_27_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_07_27_status_code_idx;


--
-- Name: request_logs_2026_08_05_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_08_05_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_08_05_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_08_05_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_08_05_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_08_05_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_08_05_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_08_05_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_08_05_model_provider_id_idx;


--
-- Name: request_logs_2026_08_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_08_05_pkey;


--
-- Name: request_logs_2026_08_05_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_08_05_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_08_05_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_08_05_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_05_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_08_05_status_code_idx;


--
-- Name: request_logs_2026_08_27_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_08_27_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_08_27_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_08_27_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_08_27_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_08_27_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_08_27_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_08_27_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_08_27_model_provider_id_idx;


--
-- Name: request_logs_2026_08_27_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_08_27_pkey;


--
-- Name: request_logs_2026_08_27_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_08_27_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_08_27_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_08_27_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_27_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_08_27_status_code_idx;


--
-- Name: request_logs_2026_08_28_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_08_28_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_08_28_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_08_28_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_08_28_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_08_28_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_08_28_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_08_28_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_08_28_model_provider_id_idx;


--
-- Name: request_logs_2026_08_28_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_08_28_pkey;


--
-- Name: request_logs_2026_08_28_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_08_28_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_08_28_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_08_28_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_28_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_08_28_status_code_idx;


--
-- Name: request_logs_2026_08_29_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_08_29_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_08_29_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_08_29_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_08_29_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_08_29_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_08_29_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_08_29_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_08_29_model_provider_id_idx;


--
-- Name: request_logs_2026_08_29_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_08_29_pkey;


--
-- Name: request_logs_2026_08_29_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_08_29_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_08_29_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_08_29_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_29_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_08_29_status_code_idx;


--
-- Name: request_logs_2026_08_30_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_08_30_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_08_30_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_08_30_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_08_30_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_08_30_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_08_30_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_08_30_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_08_30_model_provider_id_idx;


--
-- Name: request_logs_2026_08_30_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_08_30_pkey;


--
-- Name: request_logs_2026_08_30_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_08_30_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_08_30_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_08_30_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_30_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_08_30_status_code_idx;


--
-- Name: request_logs_2026_08_31_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_08_31_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_08_31_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_08_31_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_08_31_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_08_31_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_08_31_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_08_31_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_08_31_model_provider_id_idx;


--
-- Name: request_logs_2026_08_31_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_08_31_pkey;


--
-- Name: request_logs_2026_08_31_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_08_31_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_08_31_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_08_31_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_08_31_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_08_31_status_code_idx;


--
-- Name: request_logs_2026_09_01_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_01_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_01_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_01_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_01_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_01_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_01_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_01_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_01_model_provider_id_idx;


--
-- Name: request_logs_2026_09_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_01_pkey;


--
-- Name: request_logs_2026_09_01_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_01_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_01_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_01_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_01_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_01_status_code_idx;


--
-- Name: request_logs_2026_09_02_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_02_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_02_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_02_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_02_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_02_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_02_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_02_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_02_model_provider_id_idx;


--
-- Name: request_logs_2026_09_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_02_pkey;


--
-- Name: request_logs_2026_09_02_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_02_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_02_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_02_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_02_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_02_status_code_idx;


--
-- Name: request_logs_2026_09_03_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_03_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_03_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_03_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_03_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_03_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_03_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_03_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_03_model_provider_id_idx;


--
-- Name: request_logs_2026_09_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_03_pkey;


--
-- Name: request_logs_2026_09_03_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_03_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_03_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_03_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_03_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_03_status_code_idx;


--
-- Name: request_logs_2026_09_04_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_04_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_04_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_04_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_04_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_04_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_04_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_04_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_04_model_provider_id_idx;


--
-- Name: request_logs_2026_09_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_04_pkey;


--
-- Name: request_logs_2026_09_04_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_04_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_04_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_04_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_04_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_04_status_code_idx;


--
-- Name: request_logs_2026_09_05_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_05_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_05_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_05_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_05_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_05_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_05_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_05_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_05_model_provider_id_idx;


--
-- Name: request_logs_2026_09_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_05_pkey;


--
-- Name: request_logs_2026_09_05_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_05_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_05_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_05_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_05_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_05_status_code_idx;


--
-- Name: request_logs_2026_09_06_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_06_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_06_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_06_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_06_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_06_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_06_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_06_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_06_model_provider_id_idx;


--
-- Name: request_logs_2026_09_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_06_pkey;


--
-- Name: request_logs_2026_09_06_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_06_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_06_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_06_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_06_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_06_status_code_idx;


--
-- Name: request_logs_2026_09_07_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_07_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_07_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_07_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_07_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_07_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_07_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_07_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_07_model_provider_id_idx;


--
-- Name: request_logs_2026_09_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_07_pkey;


--
-- Name: request_logs_2026_09_07_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_07_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_07_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_07_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_07_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_07_status_code_idx;


--
-- Name: request_logs_2026_09_08_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_08_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_08_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_08_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_08_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_08_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_08_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_08_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_08_model_provider_id_idx;


--
-- Name: request_logs_2026_09_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_08_pkey;


--
-- Name: request_logs_2026_09_08_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_08_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_08_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_08_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_08_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_08_status_code_idx;


--
-- Name: request_logs_2026_09_09_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_09_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_09_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_09_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_09_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_09_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_09_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_09_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_09_model_provider_id_idx;


--
-- Name: request_logs_2026_09_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_09_pkey;


--
-- Name: request_logs_2026_09_09_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_09_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_09_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_09_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_09_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_09_status_code_idx;


--
-- Name: request_logs_2026_09_10_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_10_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_10_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_10_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_10_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_10_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_10_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_10_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_10_model_provider_id_idx;


--
-- Name: request_logs_2026_09_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_10_pkey;


--
-- Name: request_logs_2026_09_10_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_10_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_10_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_10_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_10_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_10_status_code_idx;


--
-- Name: request_logs_2026_09_11_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_11_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_11_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_11_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_11_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_11_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_11_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_11_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_11_model_provider_id_idx;


--
-- Name: request_logs_2026_09_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_11_pkey;


--
-- Name: request_logs_2026_09_11_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_11_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_11_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_11_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_11_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_11_status_code_idx;


--
-- Name: request_logs_2026_09_12_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_12_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_12_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_12_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_12_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_12_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_12_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_12_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_12_model_provider_id_idx;


--
-- Name: request_logs_2026_09_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_12_pkey;


--
-- Name: request_logs_2026_09_12_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_12_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_12_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_12_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_12_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_12_status_code_idx;


--
-- Name: request_logs_2026_09_13_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_13_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_13_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_13_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_13_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_13_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_13_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_13_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_13_model_provider_id_idx;


--
-- Name: request_logs_2026_09_13_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_13_pkey;


--
-- Name: request_logs_2026_09_13_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_13_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_13_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_13_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_13_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_13_status_code_idx;


--
-- Name: request_logs_2026_09_14_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_14_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_14_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_14_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_14_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_14_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_14_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_14_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_14_model_provider_id_idx;


--
-- Name: request_logs_2026_09_14_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_14_pkey;


--
-- Name: request_logs_2026_09_14_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_14_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_14_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_14_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_14_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_14_status_code_idx;


--
-- Name: request_logs_2026_09_15_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_15_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_15_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_15_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_group_member_id_inserted_at_id_provi_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_15_group_member_id_inserted_at_id_provi_id;


--
-- Name: request_logs_2026_09_15_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_15_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_15_model_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_15_model_provider_id_idx;


--
-- Name: request_logs_2026_09_15_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_15_pkey;


--
-- Name: request_logs_2026_09_15_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_15_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_15_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_15_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_15_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_15_status_code_idx;


--
-- Name: request_logs_2026_09_16_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_16_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_16_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_16_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_16_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_model_alias_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_16_model_alias_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_16_model_provider_id_idx;


--
-- Name: request_logs_2026_09_16_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_16_pkey;


--
-- Name: request_logs_2026_09_16_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_16_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_16_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_16_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_16_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_16_status_code_idx;


--
-- Name: request_logs_2026_09_16_team_member_id_inserted_at_id_provi_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_16_team_member_id_inserted_at_id_provi_idx;


--
-- Name: request_logs_2026_09_17_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_17_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_17_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_17_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_17_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_model_alias_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_17_model_alias_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_17_model_provider_id_idx;


--
-- Name: request_logs_2026_09_17_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_17_pkey;


--
-- Name: request_logs_2026_09_17_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_17_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_17_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_17_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_17_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_17_status_code_idx;


--
-- Name: request_logs_2026_09_17_team_member_id_inserted_at_id_provi_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_17_team_member_id_inserted_at_id_provi_idx;


--
-- Name: request_logs_2026_09_18_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_18_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_18_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_18_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_18_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_model_alias_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_18_model_alias_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_18_model_provider_id_idx;


--
-- Name: request_logs_2026_09_18_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_18_pkey;


--
-- Name: request_logs_2026_09_18_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_18_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_18_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_18_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_18_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_18_status_code_idx;


--
-- Name: request_logs_2026_09_18_team_member_id_inserted_at_id_provi_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_18_team_member_id_inserted_at_id_provi_idx;


--
-- Name: request_logs_2026_09_19_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_2026_09_19_agent_type_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_2026_09_19_credential_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_2026_09_19_credential_name_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_2026_09_19_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_model_alias_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_2026_09_19_model_alias_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_2026_09_19_model_provider_id_idx;


--
-- Name: request_logs_2026_09_19_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_2026_09_19_pkey;


--
-- Name: request_logs_2026_09_19_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_2026_09_19_provider_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_2026_09_19_service_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_2026_09_19_session_id_inserted_at_idx;


--
-- Name: request_logs_2026_09_19_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_2026_09_19_status_code_idx;


--
-- Name: request_logs_2026_09_19_team_member_id_inserted_at_id_provi_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_2026_09_19_team_member_id_inserted_at_id_provi_idx;


--
-- Name: request_logs_default_agent_type_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_agent_type_idx ATTACH PARTITION public.request_logs_default_agent_type_inserted_at_idx;


--
-- Name: request_logs_default_credential_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_inserted_idx ATTACH PARTITION public.request_logs_default_credential_id_inserted_at_idx;


--
-- Name: request_logs_default_credential_name_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_credential_name_idx ATTACH PARTITION public.request_logs_default_credential_name_inserted_at_idx;


--
-- Name: request_logs_default_group_member_id_inserted_at_id_provider_id; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_member_inserted_covering_idx ATTACH PARTITION public.request_logs_default_group_member_id_inserted_at_id_provider_id;


--
-- Name: request_logs_default_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_inserted_idx ATTACH PARTITION public.request_logs_default_inserted_at_idx;


--
-- Name: request_logs_default_model_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_inserted_desc_idx ATTACH PARTITION public.request_logs_default_model_id_inserted_at_idx;


--
-- Name: request_logs_default_model_provider_id_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_model_provider_id_index ATTACH PARTITION public.request_logs_default_model_provider_id_idx;


--
-- Name: request_logs_default_pkey; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_pkey ATTACH PARTITION public.request_logs_default_pkey;


--
-- Name: request_logs_default_provider_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_provider_inserted_idx ATTACH PARTITION public.request_logs_default_provider_id_inserted_at_idx;


--
-- Name: request_logs_default_service_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_service_inserted_idx ATTACH PARTITION public.request_logs_default_service_id_inserted_at_idx;


--
-- Name: request_logs_default_session_id_inserted_at_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_session_id_idx ATTACH PARTITION public.request_logs_default_session_id_inserted_at_idx;


--
-- Name: request_logs_default_status_code_idx; Type: INDEX ATTACH; Schema: public; Owner: -
--

ALTER INDEX public.request_logs_errors_idx ATTACH PARTITION public.request_logs_default_status_code_idx;


--
-- Name: api_keys api_keys_group_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_group_member_id_fkey FOREIGN KEY (group_member_id) REFERENCES public.group_members(id) ON DELETE CASCADE;


--
-- Name: api_keys api_keys_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: audit_logs audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_logs
    ADD CONSTRAINT audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: budget_exemptions budget_exemptions_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_exemptions
    ADD CONSTRAINT budget_exemptions_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE;


--
-- Name: budget_exemptions budget_exemptions_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_exemptions
    ADD CONSTRAINT budget_exemptions_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: budget_exemptions budget_exemptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_exemptions
    ADD CONSTRAINT budget_exemptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: credit_subscriptions credit_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.credit_subscriptions
    ADD CONSTRAINT credit_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: group_member_extra_models group_member_extra_models_group_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_member_extra_models
    ADD CONSTRAINT group_member_extra_models_group_member_id_fkey FOREIGN KEY (group_member_id) REFERENCES public.group_members(id);


--
-- Name: group_member_extra_models group_member_extra_models_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_member_extra_models
    ADD CONSTRAINT group_member_extra_models_model_alias_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id) ON DELETE CASCADE;


--
-- Name: group_members group_members_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id);


--
-- Name: group_members group_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_members
    ADD CONSTRAINT group_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: group_models group_models_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_models
    ADD CONSTRAINT group_models_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id);


--
-- Name: group_models group_models_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.group_models
    ADD CONSTRAINT group_models_model_alias_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id) ON DELETE CASCADE;


--
-- Name: groups groups_default_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.groups
    ADD CONSTRAINT groups_default_subscription_id_fkey FOREIGN KEY (default_subscription_id) REFERENCES public.credit_subscriptions(id) ON DELETE SET NULL;


--
-- Name: model_providers model_providers_credential_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_credential_id_fkey FOREIGN KEY (credential_id) REFERENCES public.provider_credentials(id);


--
-- Name: model_providers model_providers_exclusive_to_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_exclusive_to_group_id_fkey FOREIGN KEY (exclusive_to_group_id) REFERENCES public.groups(id) ON DELETE CASCADE;


--
-- Name: model_providers model_providers_exclusive_to_group_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_exclusive_to_group_member_id_fkey FOREIGN KEY (exclusive_to_group_member_id) REFERENCES public.group_members(id) ON DELETE CASCADE;


--
-- Name: model_providers model_providers_exclusive_to_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_exclusive_to_service_id_fkey FOREIGN KEY (exclusive_to_service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: model_providers model_providers_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.model_providers
    ADD CONSTRAINT model_providers_model_alias_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id);


--
-- Name: observability_destinations observability_destinations_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.observability_destinations
    ADD CONSTRAINT observability_destinations_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id);


--
-- Name: provider_credentials provider_credentials_provider_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.provider_credentials
    ADD CONSTRAINT provider_credentials_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES public.providers(id);


--
-- Name: request_logs request_logs_group_member_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.request_logs
    ADD CONSTRAINT request_logs_group_member_id_fkey FOREIGN KEY (group_member_id) REFERENCES public.group_members(id) ON DELETE CASCADE;


--
-- Name: request_logs request_logs_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.request_logs
    ADD CONSTRAINT request_logs_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: service_models service_model_aliases_model_alias_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_models
    ADD CONSTRAINT service_model_aliases_model_alias_id_fkey FOREIGN KEY (model_id) REFERENCES public.models(id) ON DELETE CASCADE;


--
-- Name: service_models service_model_aliases_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_models
    ADD CONSTRAINT service_model_aliases_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: service_supervisors service_supervisors_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_supervisors
    ADD CONSTRAINT service_supervisors_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(id) ON DELETE CASCADE;


--
-- Name: service_supervisors service_supervisors_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_supervisors
    ADD CONSTRAINT service_supervisors_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: services services_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE RESTRICT;


--
-- Name: services services_subscription_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_subscription_id_fkey FOREIGN KEY (subscription_id) REFERENCES public.credit_subscriptions(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict c54Iy3KJwzbUoVce0G66H7zI2WZ1thVEt5nbet6iDSC5437GyRvogyv8npAT1Yw

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
INSERT INTO public."schema_migrations" (version) VALUES (20260731072524);
INSERT INTO public."schema_migrations" (version) VALUES (20260731080000);
INSERT INTO public."schema_migrations" (version) VALUES (20260731215806);
INSERT INTO public."schema_migrations" (version) VALUES (20260801011415);
INSERT INTO public."schema_migrations" (version) VALUES (20260801014104);
INSERT INTO public."schema_migrations" (version) VALUES (20260801184912);
INSERT INTO public."schema_migrations" (version) VALUES (20260801192304);
INSERT INTO public."schema_migrations" (version) VALUES (20260802003203);
INSERT INTO public."schema_migrations" (version) VALUES (20260802044536);
INSERT INTO public."schema_migrations" (version) VALUES (20260802185404);
INSERT INTO public."schema_migrations" (version) VALUES (20260802185818);
INSERT INTO public."schema_migrations" (version) VALUES (20260805025828);
INSERT INTO public."schema_migrations" (version) VALUES (20260805025829);
INSERT INTO public."schema_migrations" (version) VALUES (20260805191213);
INSERT INTO public."schema_migrations" (version) VALUES (20260808055508);
INSERT INTO public."schema_migrations" (version) VALUES (20260808062225);
INSERT INTO public."schema_migrations" (version) VALUES (20260811024436);
INSERT INTO public."schema_migrations" (version) VALUES (20260811081628);
INSERT INTO public."schema_migrations" (version) VALUES (20260811120000);
INSERT INTO public."schema_migrations" (version) VALUES (20260811120001);
INSERT INTO public."schema_migrations" (version) VALUES (20260812130000);
INSERT INTO public."schema_migrations" (version) VALUES (20260812140000);
INSERT INTO public."schema_migrations" (version) VALUES (20260813034138);
INSERT INTO public."schema_migrations" (version) VALUES (20260813192309);
INSERT INTO public."schema_migrations" (version) VALUES (20260813193646);
INSERT INTO public."schema_migrations" (version) VALUES (20260814000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260814013243);
INSERT INTO public."schema_migrations" (version) VALUES (20260815233004);
INSERT INTO public."schema_migrations" (version) VALUES (20260815233006);
INSERT INTO public."schema_migrations" (version) VALUES (20260815233007);
INSERT INTO public."schema_migrations" (version) VALUES (20260815233008);
INSERT INTO public."schema_migrations" (version) VALUES (20260816000000);
INSERT INTO public."schema_migrations" (version) VALUES (20260816184212);
INSERT INTO public."schema_migrations" (version) VALUES (20260827045151);
INSERT INTO public."schema_migrations" (version) VALUES (20260827054110);
INSERT INTO public."schema_migrations" (version) VALUES (20260827133612);
INSERT INTO public."schema_migrations" (version) VALUES (20260827144702);
INSERT INTO public."schema_migrations" (version) VALUES (20260827150123);
INSERT INTO public."schema_migrations" (version) VALUES (20260901161239);
INSERT INTO public."schema_migrations" (version) VALUES (20260911141653);
INSERT INTO public."schema_migrations" (version) VALUES (20260912024032);
INSERT INTO public."schema_migrations" (version) VALUES (20260912042156);
INSERT INTO public."schema_migrations" (version) VALUES (20260912174033);
INSERT INTO public."schema_migrations" (version) VALUES (20260912181518);
INSERT INTO public."schema_migrations" (version) VALUES (20260912190432);
INSERT INTO public."schema_migrations" (version) VALUES (20260912193233);
INSERT INTO public."schema_migrations" (version) VALUES (20260912202852);
INSERT INTO public."schema_migrations" (version) VALUES (20260912213521);
INSERT INTO public."schema_migrations" (version) VALUES (20260913151500);
INSERT INTO public."schema_migrations" (version) VALUES (20260913151501);
INSERT INTO public."schema_migrations" (version) VALUES (20260913151502);
INSERT INTO public."schema_migrations" (version) VALUES (20260913160836);
INSERT INTO public."schema_migrations" (version) VALUES (20260913173840);
INSERT INTO public."schema_migrations" (version) VALUES (20260914044359);
INSERT INTO public."schema_migrations" (version) VALUES (20260914050417);
INSERT INTO public."schema_migrations" (version) VALUES (20260914205649);
INSERT INTO public."schema_migrations" (version) VALUES (20260914210000);
INSERT INTO public."schema_migrations" (version) VALUES (20260914232825);
INSERT INTO public."schema_migrations" (version) VALUES (20260915014829);
INSERT INTO public."schema_migrations" (version) VALUES (20260915020901);
INSERT INTO public."schema_migrations" (version) VALUES (20260915234500);
INSERT INTO public."schema_migrations" (version) VALUES (20260916010000);
