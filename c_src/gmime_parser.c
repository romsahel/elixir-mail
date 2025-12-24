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
 * Calculate trimmed length (trailing whitespace removed)
 * Matches RFC2822 parser behavior: String.trim_trailing/1
 * Uses isspace() to handle all standard whitespace characters
 */
static size_t trimmed_length(const char *str) {
    if (str == NULL) return 0;

    size_t len = strlen(str);
    while (len > 0 && isspace((unsigned char)str[len - 1])) {
        len--;
    }
    return len;
}

/*
 * RFC 2047 Robust Decoding Helper Functions
 */

/*
 * Determines if a header should receive RFC 2047 neutralization treatment
 * Returns true for unstructured text headers only
 */
static int is_rfc2047_text_header(const char *name) {
    if (name == NULL) return 0;

    // Unstructured headers that need neutralization:
    if (strcasecmp(name, "subject") == 0) return 1;
    if (strcasecmp(name, "comments") == 0) return 1;
    if (strcasecmp(name, "content-description") == 0) return 1;

    // Custom X-* headers
    if ((name[0] == 'x' || name[0] == 'X') && name[1] == '-') return 1;

    return 0;
}

/*
 * Fast lookahead validation of RFC 2047 encoded-word syntax
 * Checks format: =?charset?encoding?encoded-text?=
 * Does NOT decode - only validates structure
 *
 * Returns: length of valid encoded word if found, 0 otherwise
 */
static size_t looks_like_valid_encoded_word(const char *text, size_t pos) {
    const char *p = text + pos;

    // Must start with "=?"
    if (p[0] != '=' || p[1] != '?') return 0;
    p += 2;

    // 1. Charset token: one or more non-? non-whitespace chars
    const char *charset_start = p;
    while (*p && *p != '?' && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') {
        p++;
    }
    if (p == charset_start || *p != '?') return 0; // Empty charset or no delimiter
    p++; // Skip '?'

    // 2. Encoding: must be 'B' or 'Q' (case-insensitive)
    if (*p != 'B' && *p != 'b' && *p != 'Q' && *p != 'q') return 0;
    p++;

    // 3. Must have '?' after encoding
    if (*p != '?') return 0;
    p++;

    // 4. Encoded-text: at least one char before "?="
    const char *encoded_start = p;
    const char *end = strstr(p, "?=");
    if (end == NULL || end == encoded_start) return 0; // No closing or empty encoded-text

    // Valid encoded word found
    return (end + 2) - (text + pos); // Return total length including "=?" and "?="
}

/*
 * Neutralizes invalid "=?" sequences using different strategies:
 * - Bare =? (literal text) → ===BAREQ=== marker
 * - Invalid encoded words → = ? (space added)
 * This prevents GMime from choking on malformed input while preserving
 * valid RFC 2047 encoded-words for proper decoding
 *
 * Single-pass algorithm with minimal allocations
 * Returns: newly allocated string (caller must g_free)
 */
static char* neutralize_invalid_encoded_words(const char *text) {
    if (text == NULL) return NULL;

    size_t text_len = strlen(text);
    // Allocate extra space for potential ===BAREQ=== markers
    GString *result = g_string_sized_new(text_len + 64);

    const char *p = text;
    while (*p) {
        // Look for potential encoded word start
        if (p[0] == '=' && p[1] == '?') {
            size_t word_len = looks_like_valid_encoded_word(text, p - text);

            if (word_len > 0) {
                // Valid encoded word - copy as-is
                g_string_append_len(result, p, word_len);
                p += word_len;
            } else {
                // Invalid - distinguish between bare =? and malformed encoded word
                // Check if characters immediately after =? look like a charset (part of encoded word)
                // Malformed: =?charset?... where charset has word characters
                // Bare: =? followed by space, special chars, or nothing that looks like charset

                const char *q = p + 2;
                int looks_like_encoded_word = 0;
                int charset_len = 0;

                // Check if next chars look like a charset (alphanumeric, dash, underscore, dot)
                while (*q && *q != ' ' && *q != '\t' && *q != '\r' && *q != '\n' && charset_len < 40) {
                    if (*q == '?') {
                        // Found delimiter - this looks like it's trying to be an encoded word
                        looks_like_encoded_word = 1;
                        break;
                    } else if (isalnum((unsigned char)*q) || *q == '-' || *q == '_' || *q == '.') {
                        // Valid charset character
                        charset_len++;
                        q++;
                    } else {
                        // Invalid character for charset - probably bare =?
                        break;
                    }
                }

                if (looks_like_encoded_word && charset_len > 0) {
                    // Has format =?charset?... - looks like malformed encoded word
                    g_string_append(result, "= ?");
                    p += 2; // Skip the "=?"
                } else {
                    // Bare =? (literal text) - replace with marker
                    g_string_append(result, "===BAREQ===");
                    p += 2; // Skip the "=?"
                }
            }
        } else {
            // Regular character
            g_string_append_c(result, *p);
            p++;
        }
    }

    return g_string_free(result, FALSE); // Return char*, free GString wrapper
}

/*
 * Reverses neutralization by replacing ===BAREQ=== marker back to =?
 * Leaves = ? sequences alone (they represent invalid encoded words)
 *
 * Strategy: Find and replace marker only
 *
 * Returns: newly allocated string (caller must g_free)
 */
static char* reverse_neutralization(const char *text) {
    if (text == NULL) return NULL;

    size_t text_len = strlen(text);
    GString *result = g_string_sized_new(text_len);

    const char *p = text;
    while (*p) {
        // Look for ===BAREQ=== marker
        if (strncmp(p, "===BAREQ===", 11) == 0) {
            // Restore bare =?
            g_string_append(result, "=?");
            p += 11; // Skip marker
        } else {
            // Regular character (including = ? which we leave alone)
            g_string_append_c(result, *p);
            p++;
        }
    }

    return g_string_free(result, FALSE);
}

/*
 * Robust RFC 2047 decoder that handles bare "=?" sequences and invalid encoded words
 * Strategy: unfold → neutralize → GMime decode → restore markers
 * - Bare =? becomes ===BAREQ=== → decoded by GMime (unchanged) → restored to =?
 * - Invalid encoded words =?utf-8?X?...?= become = ?utf-8?X?...?= → unchanged → stays as = ?...
 * - Valid encoded words =?utf-8?B?...?= → unchanged → decoded by GMime → final text
 */
static char* decode_rfc2047_robust(const char *text) {
    if (text == NULL) return NULL;

    // Step 0: Unfold header using GMime's built-in function
    char *unfolded = g_mime_utils_header_unfold(text);
    if (unfolded == NULL) return NULL;

    // Skip leading whitespace
    const char *trimmed = unfolded;
    while (*trimmed && (*trimmed == ' ' || *trimmed == '\t')) {
        trimmed++;
    }

    // Step 1: Neutralize invalid "=?" sequences
    // Bare =? → ===BAREQ=== marker
    // Invalid encoded words → = ? (space added)
    char *neutralized = neutralize_invalid_encoded_words(trimmed);
    g_free(unfolded);
    if (neutralized == NULL) return NULL;

    // Step 2: Let GMime decode the cleaned text
    char *decoded = g_mime_utils_header_decode_text(NULL, neutralized);
    g_free(neutralized);

    if (decoded == NULL) return NULL;

    // Step 3: Reverse neutralization by replacing ===BAREQ=== back to =?
    // Leaves = ? sequences alone (they show invalid encoded words)
    char *final = reverse_neutralization(decoded);
    g_free(decoded);

    return final;
}

/*
 * Address Parsing
 */

static ERL_NIF_TERM convert_address_list(ErlNifEnv *env, const char *header_value) {
    if (header_value == NULL) {
        return enif_make_list(env, 0);
    }

    // Parse addresses using GMime
    InternetAddressList *addresses = internet_address_list_parse(NULL, header_value);
    if (addresses == NULL) {
        return enif_make_list(env, 0);
    }

    int count = internet_address_list_length(addresses);
    if (count == 0) {
        g_object_unref(addresses);
        return enif_make_list(env, 0);
    }

    ERL_NIF_TERM *array = malloc(sizeof(ERL_NIF_TERM) * count);
    if (array == NULL) {
        g_object_unref(addresses);
        return enif_make_list(env, 0);
    }

    for (int i = 0; i < count; i++) {
        InternetAddress *addr = internet_address_list_get_address(addresses, i);

        if (INTERNET_ADDRESS_IS_MAILBOX(addr)) {
            InternetAddressMailbox *mailbox = INTERNET_ADDRESS_MAILBOX(addr);
            const char *name = internet_address_get_name(addr);
            const char *email = internet_address_mailbox_get_addr(mailbox);

            if (name && strlen(name) > 0) {
                // {"Name", "email@example.com"}
                array[i] = enif_make_tuple2(env,
                    make_binary(env, name),
                    make_binary(env, email)
                );
            } else {
                // "email@example.com"
                array[i] = make_binary(env, email);
            }
        } else if (INTERNET_ADDRESS_IS_GROUP(addr)) {
            // Group addresses - return as string for now
            const char *name = internet_address_get_name(addr);
            array[i] = make_binary(env, name ? name : "group");
        } else {
            array[i] = make_atom(env, "nil");
        }
    }

    ERL_NIF_TERM list = enif_make_list_from_array(env, array, count);
    free(array);
    g_object_unref(addresses);

    return list;
}

static ERL_NIF_TERM convert_single_address(ErlNifEnv *env, const char *header_value) {
    if (header_value == NULL) {
        return make_atom(env, "nil");
    }

    InternetAddressList *addresses = internet_address_list_parse(NULL, header_value);
    if (addresses == NULL) {
        return make_binary(env, header_value);
    }

    int count = internet_address_list_length(addresses);
    if (count == 0) {
        g_object_unref(addresses);
        return make_binary(env, header_value);
    }

    // Get first address
    InternetAddress *addr = internet_address_list_get_address(addresses, 0);
    ERL_NIF_TERM result;

    if (INTERNET_ADDRESS_IS_MAILBOX(addr)) {
        InternetAddressMailbox *mailbox = INTERNET_ADDRESS_MAILBOX(addr);
        const char *name = internet_address_get_name(addr);
        const char *email = internet_address_mailbox_get_addr(mailbox);

        if (name && strlen(name) > 0) {
            // {"Name", "email@example.com"}
            result = enif_make_tuple2(env,
                make_binary(env, name),
                make_binary(env, email)
            );
        } else {
            // "email@example.com"
            result = make_binary(env, email);
        }
    } else {
        result = make_binary(env, header_value);
    }

    g_object_unref(addresses);
    return result;
}

/*
 * Content-Type Parsing
 */

static ERL_NIF_TERM convert_content_type(ErlNifEnv *env, const char *header_value) {
    if (header_value == NULL) {
        return enif_make_list(env, 0);
    }

    GMimeContentType *ct = g_mime_content_type_parse(NULL, header_value);
    if (ct == NULL) {
        // Return as plain string if parsing fails
        return enif_make_list_cell(env, make_binary(env, header_value), enif_make_list(env, 0));
    }

    // Build list: ["type/subtype", {"param", "value"}, ...]
    char type_subtype[256];
    const char *media_type = g_mime_content_type_get_media_type(ct);
    const char *media_subtype = g_mime_content_type_get_media_subtype(ct);

    snprintf(type_subtype, sizeof(type_subtype), "%s/%s",
             media_type ? media_type : "text",
             media_subtype ? media_subtype : "plain");

    // Start with type/subtype
    ERL_NIF_TERM list = enif_make_list(env, 0);

    // Add parameters using GMime 3.x API
    GMimeParamList *param_list = g_mime_content_type_get_parameters(ct);
    if (param_list) {
        int param_count = g_mime_param_list_length(param_list);

        // Add parameters in reverse order (will reverse at end)
        for (int i = param_count - 1; i >= 0; i--) {
            GMimeParam *param = g_mime_param_list_get_parameter_at(param_list, i);
            if (param) {
                const char *name = g_mime_param_get_name(param);
                const char *value = g_mime_param_get_value(param);

                if (name && value) {
                    ERL_NIF_TERM tuple = enif_make_tuple2(env,
                        make_binary(env, name),
                        make_binary(env, value)
                    );
                    list = enif_make_list_cell(env, tuple, list);
                }
            }
        }
    }

    // Add type/subtype at the front
    list = enif_make_list_cell(env, make_binary(env, type_subtype), list);

    g_object_unref(ct);
    return list;
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
        if (name == NULL) continue;

        // Convert header name to lowercase for header type detection
        char *key = to_lowercase(name);
        if (key == NULL) continue;

        // Determine if this header needs robust RFC 2047 decoding
        char *value = NULL;
        if (is_rfc2047_text_header(key)) {
            // Unstructured header: use robust decoder
            const char *raw_value = g_mime_header_get_raw_value(header);
            if (raw_value == NULL) {
                free(key);
                continue;
            }
            value = decode_rfc2047_robust(raw_value);
            if (value == NULL) {
                free(key);
                continue;
            }
        } else {
            // Structured or address header: use GMime's standard decoding
            const char *decoded = g_mime_header_get_value(header);
            if (decoded == NULL) {
                free(key);
                continue;
            }
            value = g_strdup(decoded); // Duplicate for consistent memory management
        }

        // Create Elixir terms based on header type
        ERL_NIF_TERM erl_key = make_binary(env, key);
        ERL_NIF_TERM erl_value;

        // Special handling for specific headers
        if (strcmp(key, "to") == 0 || strcmp(key, "cc") == 0 || strcmp(key, "bcc") == 0) {
            // Address lists
            erl_value = convert_address_list(env, value);
        } else if (strcmp(key, "from") == 0 || strcmp(key, "reply-to") == 0 || strcmp(key, "sender") == 0) {
            // Single address
            erl_value = convert_single_address(env, value);
        } else if (strcmp(key, "content-type") == 0) {
            // Structured content-type
            erl_value = convert_content_type(env, value);
        } else {
            // Plain string (already decoded and unfolded by GMime)
            // Trim trailing whitespace to match RFC2822 parser behavior
            size_t trimmed_len = trimmed_length(value);
            erl_value = make_binary_len(env, value, trimmed_len);
        }

        // For "received" headers, accumulate in a list (RFC2822 compatibility)
        if (strcmp(key, "received") == 0) {
            ERL_NIF_TERM existing_value;
            if (enif_get_map_value(env, headers_map, erl_key, &existing_value)) {
                // Received header already exists, prepend to list
                ERL_NIF_TERM new_list = enif_make_list_cell(env, erl_value, existing_value);
                enif_make_map_put(env, headers_map, erl_key, new_list, &headers_map);
            } else {
                // First received header, create a list with one element
                ERL_NIF_TERM list = enif_make_list1(env, erl_value);
                enif_make_map_put(env, headers_map, erl_key, list, &headers_map);
            }
        } else {
            // Add to map (overwrites if exists)
            enif_make_map_put(env, headers_map, erl_key, erl_value, &headers_map);
        }

        // Cleanup
        g_free(value); // Free allocated value (from decode_rfc2047_robust or g_strdup)
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

    // Get charset from Content-Type and convert to UTF-8 if needed
    GMimeContentType *content_type = g_mime_object_get_content_type(GMIME_OBJECT(mime_part));
    const char *charset = content_type ? g_mime_content_type_get_parameter(content_type, "charset") : NULL;

    ERL_NIF_TERM result;

    if (charset && g_ascii_strcasecmp(charset, "utf-8") != 0 && g_ascii_strcasecmp(charset, "us-ascii") != 0) {
        // Convert from specified charset to UTF-8
        gsize bytes_read = 0, bytes_written = 0;
        GError *error = NULL;

        char *utf8_data = g_convert((const char *)byte_array->data, byte_array->len,
                                   "UTF-8", charset,
                                   &bytes_read, &bytes_written, &error);

        if (utf8_data != NULL) {
            result = make_binary_len(env, utf8_data, bytes_written);
            g_free(utf8_data);
        } else {
            // Conversion failed, return original bytes
            if (error) g_error_free(error);
            result = make_binary_len(env, (const char *)byte_array->data, byte_array->len);
        }
    } else {
        // Already UTF-8 or no charset specified, return as-is
        result = make_binary_len(env, (const char *)byte_array->data, byte_array->len);
    }

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

            ERL_NIF_TERM erl_key = make_binary(env, key);
            ERL_NIF_TERM erl_value;

            // Special handling for specific headers
            if (strcmp(key, "to") == 0 || strcmp(key, "cc") == 0 || strcmp(key, "bcc") == 0) {
                erl_value = convert_address_list(env, value);
            } else if (strcmp(key, "from") == 0 || strcmp(key, "reply-to") == 0 || strcmp(key, "sender") == 0) {
                erl_value = convert_single_address(env, value);
            } else if (strcmp(key, "content-type") == 0) {
                erl_value = convert_content_type(env, value);
            } else {
                erl_value = make_binary(env, value);
            }

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
 * Extract headers using GMime's message-level APIs
 * These APIs correctly handle RFC 2047 decoding
 */
static void override_message_headers(ErlNifEnv *env, GMimeMessage *message, ERL_NIF_TERM *headers) {
    // Override "subject" header using our custom robust RFC 2047 decoder
    // This handles edge cases like bare "=?" sequences that confuse GMime's decoder
    const char *raw_subject = g_mime_object_get_header(GMIME_OBJECT(message), "Subject");
    if (raw_subject) {
        char *decoded_subject = decode_rfc2047_robust(raw_subject);
        if (decoded_subject) {
            ERL_NIF_TERM key = make_binary(env, "subject");
            size_t trimmed_len = trimmed_length(decoded_subject);
            ERL_NIF_TERM value = make_binary_len(env, decoded_subject, trimmed_len);
            enif_make_map_put(env, *headers, key, value, headers);
            g_free(decoded_subject);
        }
    }
    // Override "from" header using g_mime_message_get_from()
    InternetAddressList *from_list = g_mime_message_get_from(message);
    if (from_list && internet_address_list_length(from_list) > 0) {
        InternetAddress *addr = internet_address_list_get_address(from_list, 0);
        if (INTERNET_ADDRESS_IS_MAILBOX(addr)) {
            InternetAddressMailbox *mailbox = INTERNET_ADDRESS_MAILBOX(addr);
            const char *name = internet_address_get_name(addr);
            const char *email = internet_address_mailbox_get_addr(mailbox);

            ERL_NIF_TERM from_value;
            if (name && strlen(name) > 0) {
                from_value = enif_make_tuple2(env,
                    make_binary(env, name),
                    make_binary(env, email)
                );
            } else {
                from_value = make_binary(env, email);
            }

            ERL_NIF_TERM key = make_binary(env, "from");
            enif_make_map_put(env, *headers, key, from_value, headers);
        }
    }

    // Override "reply-to" header using g_mime_message_get_reply_to()
    InternetAddressList *reply_to_list = g_mime_message_get_reply_to(message);
    if (reply_to_list && internet_address_list_length(reply_to_list) > 0) {
        InternetAddress *addr = internet_address_list_get_address(reply_to_list, 0);
        if (INTERNET_ADDRESS_IS_MAILBOX(addr)) {
            InternetAddressMailbox *mailbox = INTERNET_ADDRESS_MAILBOX(addr);
            const char *name = internet_address_get_name(addr);
            const char *email = internet_address_mailbox_get_addr(mailbox);

            ERL_NIF_TERM reply_to_value;
            if (name && strlen(name) > 0) {
                reply_to_value = enif_make_tuple2(env,
                    make_binary(env, name),
                    make_binary(env, email)
                );
            } else {
                reply_to_value = make_binary(env, email);
            }

            ERL_NIF_TERM key = make_binary(env, "reply-to");
            enif_make_map_put(env, *headers, key, reply_to_value, headers);
        }
    }
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

    // Override headers using GMime's message-level APIs
    // This ensures proper RFC 2047 decoding for subject, addresses, etc.
    override_message_headers(env, message, &headers);

    // Get the MIME part (body content)
    GMimeObject *mime_part = g_mime_message_get_mime_part(message);

    // Add Content-Type from MIME part if not already in headers
    if (mime_part) {
        GMimeContentType *ct = g_mime_object_get_content_type(mime_part);
        if (ct) {
            // Build content-type string with parameters
            char *ct_string = g_mime_content_type_get_mime_type(ct);
            if (ct_string) {
                // Get the mime type
                const char *media_type = g_mime_content_type_get_media_type(ct);
                const char *media_subtype = g_mime_content_type_get_media_subtype(ct);

                // Build the structured format
                char type_subtype[256];
                snprintf(type_subtype, sizeof(type_subtype), "%s/%s",
                         media_type ? media_type : "text",
                         media_subtype ? media_subtype : "plain");

                ERL_NIF_TERM list = enif_make_list(env, 0);

                // Add parameters
                GMimeParamList *param_list = g_mime_content_type_get_parameters(ct);
                if (param_list) {
                    int param_count = g_mime_param_list_length(param_list);
                    for (int i = param_count - 1; i >= 0; i--) {
                        GMimeParam *param = g_mime_param_list_get_parameter_at(param_list, i);
                        if (param) {
                            const char *name = g_mime_param_get_name(param);
                            const char *value = g_mime_param_get_value(param);
                            if (name && value) {
                                ERL_NIF_TERM tuple = enif_make_tuple2(env,
                                    make_binary(env, name),
                                    make_binary(env, value)
                                );
                                list = enif_make_list_cell(env, tuple, list);
                            }
                        }
                    }
                }

                // Add type/subtype at front
                list = enif_make_list_cell(env, make_binary(env, type_subtype), list);

                ERL_NIF_TERM ct_key = make_binary(env, "content-type");

                // Only add if not already present
                ERL_NIF_TERM existing;
                if (!enif_get_map_value(env, headers, ct_key, &existing)) {
                    enif_make_map_put(env, headers, ct_key, list, &headers);
                }

                g_free(ct_string);
            }
        }
    }

    // Extract body
    ERL_NIF_TERM body = mime_part ? extract_body(env, mime_part) : make_atom(env, "nil");

    // Check if multipart
    int is_multipart = mime_part && GMIME_IS_MULTIPART(mime_part);
    ERL_NIF_TERM multipart = is_multipart ? make_atom(env, "true") : make_atom(env, "false");

    // Convert parts if multipart
    ERL_NIF_TERM parts = is_multipart ? convert_parts(env, mime_part) : enif_make_list(env, 0);

    // Special case: multipart with no parts (e.g., declares multipart content-type but no boundary markers in body)
    // In this case, try to extract the preamble or epilogue as the body content
    if (is_multipart) {
        unsigned int part_count = 0;
        enif_get_list_length(env, parts, &part_count);

        if (part_count == 0) {
            GMimeMultipart *mp = GMIME_MULTIPART(mime_part);

            // Check preamble first (content before first boundary, or all content if no boundaries)
            const char *preamble = g_mime_multipart_get_prologue(mp);
            if (preamble && strlen(preamble) > 0) {
                body = make_binary(env, preamble);
            } else {
                // If no preamble, check epilogue (content after last boundary)
                const char *epilogue = g_mime_multipart_get_epilogue(mp);
                if (epilogue && strlen(epilogue) > 0) {
                    body = make_binary(env, epilogue);
                }
            }
        }
    }

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
