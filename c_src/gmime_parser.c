/*
 * GMime Parser Implementation
 *
 * Core functions for converting GMime messages to Elixir Mail.Message structs
 */

#include "gmime_parser.h"
#include <string.h>
#include <stdio.h>

/*
 * Helper Functions for Elixir Term Construction
 */

ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *atom_name) {
    ERL_NIF_TERM atom;
    if (enif_make_existing_atom(env, atom_name, &atom, ERL_NIF_LATIN1)) {
        return atom;
    }
    return enif_make_atom(env, atom_name);
}

ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *str) {
    if (str == NULL) {
        return make_atom(env, "nil");
    }
    return make_binary_len(env, str, strlen(str));
}

ERL_NIF_TERM make_binary_len(ErlNifEnv *env, const char *str, size_t len) {
    ErlNifBinary binary;
    if (!enif_alloc_binary(len, &binary)) {
        return make_atom(env, "nil");
    }
    memcpy(binary.data, str, len);
    return enif_make_binary(env, &binary);
}

ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value) {
    return enif_make_tuple2(env, make_atom(env, "ok"), value);
}

ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *reason) {
    return enif_make_tuple2(env,
        make_atom(env, "error"),
        make_binary(env, reason)
    );
}

/*
 * Convert string to lowercase (for header keys)
 */
static char* to_lowercase(const char *str) {
    if (str == NULL) return NULL;

    size_t len = strlen(str);
    char *lower = malloc(len + 1);
    if (lower == NULL) return NULL;

    for (size_t i = 0; i < len; i++) {
        lower[i] = tolower((unsigned char)str[i]);
    }
    lower[len] = '\0';

    return lower;
}

/*
 * Header Conversion
 */

static ERL_NIF_TERM convert_headers(ErlNifEnv *env, GMimeMessage *message) {
    ERL_NIF_TERM headers_map = enif_make_new_map(env);

    // Get header list from message
    GMimeHeaderList *header_list = g_mime_object_get_header_list(GMIME_OBJECT(message));
    if (header_list == NULL) {
        return headers_map;
    }

    int count = g_mime_header_list_get_count(header_list);

    for (int i = 0; i < count; i++) {
        GMimeHeader *header = g_mime_header_list_get_header_at(header_list, i);
        if (header == NULL) continue;

        const char *name = g_mime_header_get_name(header);
        const char *value = g_mime_header_get_value(header);  // Use get_value instead of get_raw_value

        if (name == NULL || value == NULL) continue;

        // Convert header name to lowercase
        char *key = to_lowercase(name);
        if (key == NULL) continue;

        // value from g_mime_header_get_value is already decoded and unfolded
        const char *final_value = value;

        // Create Elixir terms
        ERL_NIF_TERM erl_key = make_binary(env, key);
        ERL_NIF_TERM erl_value = make_binary(env, final_value);

        // Add to map
        enif_make_map_put(env, headers_map, erl_key, erl_value, &headers_map);

        // Cleanup
        free(key);
    }

    return headers_map;
}

/*
 * Body Extraction with Decoding
 */

static ERL_NIF_TERM extract_body(ErlNifEnv *env, GMimeObject *part) {
    // If it's multipart, body is nil
    if (GMIME_IS_MULTIPART(part)) {
        return make_atom(env, "nil");
    }

    // If it's not a MIME part, return nil
    if (!GMIME_IS_PART(part)) {
        return make_atom(env, "nil");
    }

    GMimePart *mime_part = GMIME_PART(part);
    GMimeDataWrapper *content = g_mime_part_get_content(mime_part);

    if (content == NULL) {
        return make_atom(env, "nil");
    }

    // Create memory stream for decoded output
    GMimeStream *mem_stream = g_mime_stream_mem_new();
    if (mem_stream == NULL) {
        return make_atom(env, "nil");
    }

    // Write decoded content to memory stream
    // This automatically handles base64, quoted-printable, etc.
    gssize bytes_written = g_mime_data_wrapper_write_to_stream(content, mem_stream);

    if (bytes_written < 0) {
        g_object_unref(mem_stream);
        return make_atom(env, "nil");
    }

    // Get the decoded bytes
    GByteArray *byte_array = g_mime_stream_mem_get_byte_array(GMIME_STREAM_MEM(mem_stream));

    if (byte_array == NULL || byte_array->len == 0) {
        g_object_unref(mem_stream);
        return make_binary_len(env, "", 0);
    }

    // Create Elixir binary
    ERL_NIF_TERM result = make_binary_len(env, (const char *)byte_array->data, byte_array->len);

    g_object_unref(mem_stream);

    return result;
}

/*
 * Multipart Parts Conversion
 */

static ERL_NIF_TERM convert_parts(ErlNifEnv *env, GMimeObject *object);  // Forward declaration

static ERL_NIF_TERM gmime_object_to_mail_message(ErlNifEnv *env, GMimeObject *part) {
    // Build headers map
    GMimeHeaderList *header_list = g_mime_object_get_header_list(part);
    ERL_NIF_TERM headers_map = enif_make_new_map(env);

    if (header_list != NULL) {
        int count = g_mime_header_list_get_count(header_list);

        for (int i = 0; i < count; i++) {
            GMimeHeader *header = g_mime_header_list_get_header_at(header_list, i);
            if (header == NULL) continue;

            const char *name = g_mime_header_get_name(header);
            const char *value = g_mime_header_get_value(header);

            if (name == NULL || value == NULL) continue;

            char *key = to_lowercase(name);
            if (key == NULL) continue;

            const char *final_value = value;

            ERL_NIF_TERM erl_key = make_binary(env, key);
            ERL_NIF_TERM erl_value = make_binary(env, final_value);

            enif_make_map_put(env, headers_map, erl_key, erl_value, &headers_map);

            free(key);
        }
    }

    // Extract body
    ERL_NIF_TERM body = extract_body(env, part);

    // Check if multipart
    int is_multipart = GMIME_IS_MULTIPART(part);
    ERL_NIF_TERM multipart = is_multipart ? make_atom(env, "true") : make_atom(env, "false");

    // Convert parts if multipart
    ERL_NIF_TERM parts = is_multipart ? convert_parts(env, part) : enif_make_list(env, 0);

    // Build Mail.Message struct
    ERL_NIF_TERM struct_key = make_atom(env, "__struct__");
    ERL_NIF_TERM module_name = make_atom(env, "Elixir.Mail.Message");

    ERL_NIF_TERM result = enif_make_new_map(env);
    enif_make_map_put(env, result, struct_key, module_name, &result);
    enif_make_map_put(env, result, make_atom(env, "headers"), headers_map, &result);
    enif_make_map_put(env, result, make_atom(env, "body"), body, &result);
    enif_make_map_put(env, result, make_atom(env, "multipart"), multipart, &result);
    enif_make_map_put(env, result, make_atom(env, "parts"), parts, &result);

    return result;
}

static ERL_NIF_TERM convert_parts(ErlNifEnv *env, GMimeObject *object) {
    if (!GMIME_IS_MULTIPART(object)) {
        return enif_make_list(env, 0);  // Empty list
    }

    GMimeMultipart *multipart = GMIME_MULTIPART(object);
    int count = g_mime_multipart_get_count(multipart);

    if (count == 0) {
        return enif_make_list(env, 0);
    }

    // Build list of parts
    ERL_NIF_TERM *parts = malloc(sizeof(ERL_NIF_TERM) * count);
    if (parts == NULL) {
        return enif_make_list(env, 0);
    }

    for (int i = 0; i < count; i++) {
        GMimeObject *part = g_mime_multipart_get_part(multipart, i);
        if (part != NULL) {
            parts[i] = gmime_object_to_mail_message(env, part);
        } else {
            parts[i] = make_atom(env, "nil");
        }
    }

    ERL_NIF_TERM result = enif_make_list_from_array(env, parts, count);
    free(parts);

    return result;
}

/*
 * Main Conversion: GMimeMessage -> Mail.Message
 */

ERL_NIF_TERM gmime_message_to_mail_message(ErlNifEnv *env, GMimeMessage *message) {
    if (message == NULL) {
        return make_error_tuple(env, "null_message");
    }

    // Convert main headers
    ERL_NIF_TERM headers = convert_headers(env, message);

    // Get the MIME part (body content)
    GMimeObject *mime_part = g_mime_message_get_mime_part(message);

    // Extract body
    ERL_NIF_TERM body = mime_part ? extract_body(env, mime_part) : make_atom(env, "nil");

    // Check if multipart
    int is_multipart = mime_part && GMIME_IS_MULTIPART(mime_part);
    ERL_NIF_TERM multipart = is_multipart ? make_atom(env, "true") : make_atom(env, "false");

    // Convert parts if multipart
    ERL_NIF_TERM parts = is_multipart ? convert_parts(env, mime_part) : enif_make_list(env, 0);

    // Build Mail.Message struct map
    ERL_NIF_TERM struct_key = make_atom(env, "__struct__");
    ERL_NIF_TERM module_name = make_atom(env, "Elixir.Mail.Message");

    ERL_NIF_TERM result = enif_make_new_map(env);
    enif_make_map_put(env, result, struct_key, module_name, &result);
    enif_make_map_put(env, result, make_atom(env, "headers"), headers, &result);
    enif_make_map_put(env, result, make_atom(env, "body"), body, &result);
    enif_make_map_put(env, result, make_atom(env, "multipart"), multipart, &result);
    enif_make_map_put(env, result, make_atom(env, "parts"), parts, &result);

    return result;
}

/*
 * Parse from any GMime stream
 */

ERL_NIF_TERM parse_from_stream(ErlNifEnv *env, GMimeStream *stream) {
    if (stream == NULL) {
        return make_error_tuple(env, "null_stream");
    }

    // Create parser from stream
    GMimeParser *parser = g_mime_parser_new_with_stream(stream);
    if (parser == NULL) {
        return make_error_tuple(env, "failed_to_create_parser");
    }

    // Parse the message (GMime 3.x API - no GError parameter)
    GMimeMessage *message = g_mime_parser_construct_message(parser, NULL);

    g_object_unref(parser);

    if (message == NULL) {
        return make_error_tuple(env, "failed_to_parse_message");
    }

    // Convert to Mail.Message struct
    ERL_NIF_TERM mail_message = gmime_message_to_mail_message(env, message);

    g_object_unref(message);

    return make_ok_tuple(env, mail_message);
}
