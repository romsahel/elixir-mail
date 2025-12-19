/*
 * GMime NIF for Elixir Mail Parser
 *
 * Provides high-performance RFC 2822 email parsing using GMime C library.
 */

#include <erl_nif.h>
#include <gmime/gmime.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include "gmime_parser.h"

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
 * NIF Functions
 */

static ERL_NIF_TERM parse_stream_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // Extract file path from binary
    ErlNifBinary path_binary;
    if (!enif_inspect_binary(env, argv[0], &path_binary)) {
        return make_error_tuple(env, "invalid_file_path");
    }

    // Null-terminate the path
    char file_path[4096];
    if (path_binary.size >= sizeof(file_path)) {
        return make_error_tuple(env, "file_path_too_long");
    }

    memcpy(file_path, path_binary.data, path_binary.size);
    file_path[path_binary.size] = '\0';

    // Open file
    int fd = open(file_path, O_RDONLY);
    if (fd < 0) {
        return make_error_tuple(env, "failed_to_open_file");
    }

    // Create GMime file stream
    GMimeStream *stream = g_mime_stream_fs_new(fd);
    if (stream == NULL) {
        close(fd);
        return make_error_tuple(env, "failed_to_create_stream");
    }

    // Parse from stream
    ERL_NIF_TERM result = parse_from_stream(env, stream);

    // Cleanup
    g_object_unref(stream);
    // Note: GMimeStreamFs takes ownership of fd and closes it

    return result;
}

static ERL_NIF_TERM parse_string_nif(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 2) {
        return enif_make_badarg(env);
    }

    // Extract binary
    ErlNifBinary email_binary;
    if (!enif_inspect_binary(env, argv[0], &email_binary)) {
        return enif_make_badarg(env);
    }

    // Create GMime memory stream
    GMimeStream *stream = g_mime_stream_mem_new_with_buffer(
        (const char *)email_binary.data,
        email_binary.size
    );

    if (stream == NULL) {
        return make_error_tuple(env, "failed_to_create_memory_stream");
    }

    // Parse from stream
    ERL_NIF_TERM result = parse_from_stream(env, stream);

    // Cleanup
    g_object_unref(stream);

    return result;
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
