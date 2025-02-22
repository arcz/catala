(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Emile Rolley <emile.rolley@tuta.io>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** Utility functions used for file manipulation. *)

val with_out_channel : string -> (out_channel -> 'a) -> 'a
(** Runs the given function with the provided file opened, ensuring it is
    properly closed afterwards. May raise just as [open_out]. *)

val with_in_channel : string -> (in_channel -> 'a) -> 'a
(** Runs the given function with the provided file opened, ensuring it is
    properly closed afterwards. May raise just as [open_in]. *)

(** {2 Formatter wrappers} *)

val with_formatter_of_out_channel :
  out_channel -> (Format.formatter -> 'a) -> 'a
(** [with_formatter_of_out_channel oc f] creates an flushes the formatter used
    in [f] from the given out_channel [oc]. *)

val with_formatter_of_file : string -> (Format.formatter -> 'a) -> 'a
(** [with_formatter_of_file filename f] manages the formatter created from the
    file [filename] used in [f] -- i.e. closes the corresponding out_channel and
    flushes the formatter. *)

val with_formatter_of_opt_file : string option -> (Format.formatter -> 'a) -> 'a
(** [with_formatter_of_opt_file filename_opt f] manages the formatter created
    from the file [filename_opt] if there is some (see
    {!with_formatter_of_file}), otherwise, uses the [Format.std_formatter]. *)

val get_out_channel :
  source_file:Cli.input_file ->
  output_file:string option ->
  ?ext:string ->
  unit ->
  string option * ((out_channel -> 'a) -> 'a)
(** [get_output ~source_file ~output_file ?ext ()] returns the infered filename
    and its corresponding [with_out_channel] function. If the [output_file] is
    equal to [Some "-"] returns a wrapper around [stdout]. *)

val get_formatter_of_out_channel :
  source_file:Cli.input_file ->
  output_file:string option ->
  ?ext:string ->
  unit ->
  string option * ((Format.formatter -> 'a) -> 'a)
(** [get_output_format ~source_file ~output_file ?ext ()] returns the infered
    filename and its corresponding [with_formatter_of_out_channel] function. If
    the [output_file] is equal to [Some "-"] returns a wrapper around [stdout]. *)

val temp_file : string -> string -> string
(** Like [Filename.temp_file], but registers the file for deletion at program
    exit unless Cli.debug_flag is set. *)

val with_temp_file :
  string -> string -> ?contents:string -> (string -> 'a) -> 'a
(** Creates a temp file (with prefix and suffix like [temp_file], optionally
    with the given contents, for the lifetime of the supplied function, then
    remove it unconditionally *)

val contents : string -> string
(** Reads the contents of a file as a string *)

val process_out : ?check_exit:(int -> unit) -> string -> string list -> string
(** [process_out cmd args] executes the given command with the specified
    arguments, and returns the stdout of the process as a string. [check_exit]
    is called on the return code of the sub-process, the default is to fail on
    anything but 0. *)

val check_directory : string -> string option
(** Checks if the given directory exists and returns it normalised (as per
    [Unix.realpath]). *)

val ( / ) : string -> string -> string
(** [Filename.concat]: Sugar to allow writing
    [File.("some" / "relative" / "path")] *)
