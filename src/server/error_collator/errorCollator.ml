(**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open ServerEnv
open Utils_js

(* combine error maps into a single error set and a filtered warning map
 *
 * This can be a little expensive for large repositories and can take a couple of seconds.
 * Therefore there are a few things we want to do:
 *
 * 1. Memoize the result in env. This means subsequent calls to commands like `flow status` can
 *    be fast
 * 2. Eagerly calculate `collate_errors` after init or a recheck, so that the server still has
 *    the init or recheck lock. If we improve how clients can tell if a server is busy or stuck
 *    then we can probably relax this.
 * 3. Throw away the collated errors when lazy mode's typecheck_contents adds more dependents or
 *    dependencies to the checked set
 **)
let regenerate =
  let open Errors in
  let open Error_suppressions in
  let add_unused_suppression_warnings checked unused warnings =
    (* For each unused suppression, create an warning *)
    let deps = CheckedSet.dependencies checked in
    Error_suppressions.all_locs unused
    |> List.fold_left
      (fun warnings loc ->
        let source_file = match Loc.source loc with Some x -> x | None -> File_key.SourceFile "-" in
        (* In lazy mode, dependencies are modules which we typecheck not because we care about
         * them, but because something important (a focused file or a focused file's dependent)
         * needs these dependencies. Therefore, we might not typecheck a dependencies' dependents.
         *
         * This means there might be an unused suppression comment warning in a dependency which
         * only shows up in lazy mode. To avoid this, we'll just avoid raising this kind of
         * warning in any dependency.*)
        if not (FilenameSet.mem source_file deps)
        then begin
          let err =
            let msg = Error_message.EUnusedSuppression (ALoc.of_loc loc) in
            Flow_error.error_of_msg ~trace_reasons:[] ~source_file msg in
          let err = Errors.concretize_printable_error err in
          let file_warnings = FilenameMap.get source_file warnings
            |> Option.value ~default:ConcreteLocPrintableErrorSet.empty
            |> ConcreteLocPrintableErrorSet.add err in
          FilenameMap.add source_file file_warnings warnings
        end else
          warnings
      )
      warnings
  in
  let acc_fun (type a) suppressions (f : File_key.t -> ConcreteLocPrintableErrorSet.t -> a -> a)
    filename file_errs (errors, suppressed, unused) =
    let file_errs, file_suppressed, unused =
      Errors.concretize_printable_errorset file_errs
      |> filter_suppressed_errors suppressions ~unused in
    let errors = f filename file_errs errors in
    let suppressed = List.rev_append file_suppressed suppressed in
    (errors, suppressed, unused)
  in
  fun env ->
    MonitorRPC.status_update ~event:ServerStatus.Collating_errors_start;
    let {
      ServerEnv.local_errors; merge_errors; warnings; suppressions;
    } = env.ServerEnv.errors in

    let acc_err_fun = acc_fun suppressions (fun _ -> ConcreteLocPrintableErrorSet.union) in
    let collated_errorset, collated_suppressed_errors, unused =
      (ConcreteLocPrintableErrorSet.empty, [], suppressions)
      |> FilenameMap.fold acc_err_fun local_errors
      |> FilenameMap.fold acc_err_fun merge_errors
    in

    let acc_warn_fun = acc_fun suppressions FilenameMap.add in
    let warnings, collated_suppressed_errors, unused =
      (FilenameMap.empty, collated_suppressed_errors, unused)
      |> FilenameMap.fold acc_warn_fun warnings
    in

    let collated_warning_map =
      add_unused_suppression_warnings env.ServerEnv.checked_files unused warnings in
    { collated_errorset; collated_warning_map; collated_suppressed_errors }

let get_with_separate_warnings env =
  let open ServerEnv in
  let collated_errors = match !(env.collated_errors) with
  | None ->
    let collated_errors = regenerate env in
    env.collated_errors := Some collated_errors;
    collated_errors
  | Some collated_errors ->
    collated_errors
  in
  let { collated_errorset; collated_warning_map; collated_suppressed_errors } = collated_errors in
  (collated_errorset, collated_warning_map, collated_suppressed_errors)

(* combine error maps into a single error set and a single warning set *)
let get env =
  let open Errors in
  let errors, warning_map, suppressed_errors = get_with_separate_warnings env in
  let warnings = FilenameMap.fold (fun _key -> ConcreteLocPrintableErrorSet.union) warning_map ConcreteLocPrintableErrorSet.empty in
  (errors, warnings, suppressed_errors)
