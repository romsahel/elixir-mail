/*
 * GMime Parser - Core parsing functions
 *
 * Converts GMime messages to Elixir Mail.Message structs
 */

#ifndef GMIME_PARSER_H
#define GMIME_PARSER_H

#include <erl_nif.h>
#include <gmime/gmime.h>

/*
 * Main parsing function - converts GMimeMessage to Mail.Message struct
 */
ERL_NIF_TERM gmime_message_to_mail_message(ErlNifEnv *env, GMimeMessage *message);

/*
 * Parse email from any GMime stream
 */
ERL_NIF_TERM parse_from_stream(ErlNifEnv *env, GMimeStream *stream);

/*
 * Helper functions for creating Elixir terms
 */
ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *atom_name);
ERL_NIF_TERM make_binary(ErlNifEnv *env, const char *str);
ERL_NIF_TERM make_binary_len(ErlNifEnv *env, const char *str, size_t len);
ERL_NIF_TERM make_ok_tuple(ErlNifEnv *env, ERL_NIF_TERM value);
ERL_NIF_TERM make_error_tuple(ErlNifEnv *env, const char *reason);

#endif // GMIME_PARSER_H
