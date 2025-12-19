/*
 * GMime NIF for Elixir Mail Parser
 *
 * Provides high-performance RFC 2822 email parsing using GMime C library.
 */

#include <erl_nif.h>
#include <gmime/gmime.h>
#include <string.h>

/*
 * Resource Types
 */
static ErlNifResourceType *GMIME_MESSAGE_RESOURCE;

typedef struct {
    GMimeMessage *message;
} GmimeMessageResource;

/*
 * Resource Destructors
 */
static void gmime_message_destructor(ErlNifEnv *env, void *obj) {
    GmimeMessageResource *resource = (GmimeMessageResource *)obj;
    if (resource->message != NULL) {
        g_object_unref(resource->message);
        resource->message = NULL;
    }
}

/*
 * Helper Functions
 */

static ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *atom_name) {
    ERL_NIF_TERM atom;
    if (enif_make_existing_atom(env, atom_name, &atom, ERL_NIF_LATIN1)) {
        return atom;
    }
    return enif_make_atom(env, atom_name);
}

static ERL_NIF_TERM make_ok(ErlNifEnv *env) {
    return make_atom(env, "ok");
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env,
        make_atom(env, "error"),
        make_atom(env, reason)
    );
}

/*
 * NIF Functions (Stubs for Phase 1)
 */

static ERL_NIF_TERM parse_string_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Stub implementation - will be completed in Phase 2
    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // Validate that first argument is a binary
    ErlNifBinary email_binary;
    if (!enif_inspect_binary(env, argv[0], &email_binary)) {
        return enif_make_badarg(env);
    }

    // For now, just return :ok to test NIF loading
    return make_ok(env);
}

static ERL_NIF_TERM parse_stream_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Stub implementation - will be completed in Phase 3
    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // For now, just return :ok to test NIF loading
    return make_ok(env);
}

/*
 * NIF Module Initialization
 */

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    // Initialize GMime library
    g_mime_init();

    // Create resource type for GMime messages
    GMIME_MESSAGE_RESOURCE = enif_open_resource_type(
        env,
        NULL,
        "gmime_message",
        gmime_message_destructor,
        ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER,
        NULL
    );

    if (GMIME_MESSAGE_RESOURCE == NULL) {
        return -1;
    }

    *priv_data = NULL;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv_data) {
    // Shutdown GMime library
    g_mime_shutdown();
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info) {
    // No upgrade logic needed yet
    return 0;
}

/*
 * NIF Function Exports
 */
static ErlNifFunc nif_funcs[] = {
    {"parse_string_nif", 2, parse_string_nif, 0},
    {"parse_stream_nif", 2, parse_stream_nif, 0}
};

ERL_NIF_INIT(Elixir.Mail.Parsers.GMime.NIF, nif_funcs, load, NULL, upgrade, unload)
