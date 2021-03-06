module Rfc6532 = Rfc6532
module Rfc2047 = Rfc2047
module Rfc2046 = Rfc2046
module Rfc2045 = Rfc2045
module Rfc822 = Rfc822
module Field = Field

type 'id t =
  | Contents of 'id
  | Multipart of 'id atom list
and 'id atom =
  { fields : Field.field list
  ; contents : 'id t option }

type 'id emitters = Field.field list -> (string option -> unit) * 'id

module B64 = struct
  open Angstrom

  let parser ~write_data end_of_body =
    let dec = Base64_rfc2045.decoder `Manual in

    let check_end_of_body =
      let expected_len = String.length end_of_body in
      Unsafe.peek expected_len
        (fun ba ~off ~len ->
          let raw = Bigstringaf.substring ba ~off ~len in
          String.equal raw end_of_body) in

    let trailer () =
      let rec finish () = match Base64_rfc2045.decode dec with
        | `Await -> assert false
        | `Flush data -> write_data data ; finish ()
        | `Malformed err -> fail err
        | `Wrong_padding -> fail "wrong padding"
        | `End -> commit

      and go () = match Base64_rfc2045.decode dec with
        | `Await ->
          Base64_rfc2045.src dec Bytes.empty 0 0 ; finish ()
        | `Flush data -> write_data data ; go ()
        | `Malformed err -> fail err
        | `Wrong_padding -> fail "wrong padding"
        | `End -> commit in

      go () in

    fix @@ fun m ->
    let choose chunk = function
      | true ->
        let chunk = Bytes.sub chunk 0 (Bytes.length chunk - 1) in
        Base64_rfc2045.src dec chunk 0 (Bytes.length chunk) ; trailer ()
      | false ->
        Bytes.set chunk (Bytes.length chunk - 1) end_of_body.[0] ;
        Base64_rfc2045.src dec chunk 0 (Bytes.length chunk) ;
        advance 1 *> m in

    Unsafe.take_while ((<>) end_of_body.[0]) Bigstringaf.substring
    >>= fun chunk ->
    let rec go () = match Base64_rfc2045.decode dec with
      | `End -> commit
      | `Await ->
        let chunk' = Bytes.create (String.length chunk + 1) in
        Bytes.blit_string chunk 0 chunk' 0 (String.length chunk) ;
        check_end_of_body >>= choose chunk'
      | `Flush data ->
        write_data data ; go ()
      | `Malformed err -> fail err
      | `Wrong_padding -> fail "wrong padding" in
    go ()

  let with_push ~push end_of_body =
    let write_data x = push (Some x) in
    parser ~write_data end_of_body

  let to_end_of_input ~write_data =
    let dec = Base64_rfc2045.decoder `Manual in

    fix @@ fun m -> match Base64_rfc2045.decode dec with
    | `End -> commit
    | `Await ->
      (peek_char >>= function
        | None -> Base64_rfc2045.src dec Bytes.empty 0 0 ; return ()
        | Some _ -> available >>= fun n -> Unsafe.take n
            (fun ba ~off ~len ->
              let chunk = Bytes.create len in
              Bigstringaf.blit_to_bytes ba ~src_off:off chunk ~dst_off:0 ~len ;
              Base64_rfc2045.src dec chunk 0 len)
          >>= fun () -> m)
    | `Flush data -> write_data data ; m
    | `Malformed err -> fail err
    | `Wrong_padding -> fail "wrong padding"

  let to_end_of_input_with_push push =
    let write_data x = push (Some x) in
    to_end_of_input ~write_data
end

module RAW = struct
  open Angstrom

  let parser ~write_data ~write_line end_of_body =
    let check_end_of_body =
      let expected_len = String.length end_of_body in
      Unsafe.peek expected_len
        (fun ba ~off ~len ->
          let raw = Bigstringaf.substring ba ~off ~len in
          String.equal raw end_of_body) in

    fix @@ fun m ->
    let choose chunk = function
      | true ->
        let chunk = Bytes.sub_string chunk 0 (Bytes.length chunk - 1) in
        write_data chunk ; commit
      | false ->
        (* [\r] *)
        peek_char >>= function
        | Some '\r' ->
          ( advance 1 *> peek_char >>= function
              | Some '\n' ->
                let chunk = Bytes.sub_string chunk 0 (Bytes.length chunk - 1) in
                write_line chunk ;
                advance 1 *> commit *> m
              | Some _ | None ->
                Bytes.set chunk (Bytes.length chunk - 1) end_of_body.[0] ;
                write_data (Bytes.unsafe_to_string chunk) ;
                advance 1 *> commit *> m )
        | Some _ | None ->
          let chunk = Bytes.sub_string chunk 0 (Bytes.length chunk - 1) in
          write_data chunk ;
          commit in

    take_while ((<>) end_of_body.[0])
    >>= fun chunk ->
    let chunk' = Bytes.create (String.length chunk + 1) in
    Bytes.blit_string chunk 0 chunk' 0 (String.length chunk) ;
    check_end_of_body >>= choose chunk'

  let with_push ?(end_of_line = "\n") ~push end_of_body =
    let write_data x = push (Some x) in
    let write_line x = push (Some (x ^ end_of_line)) in
    parser ~write_data ~write_line end_of_body

  let to_end_of_input ~write_data ~write_line =
    fix @@ fun m ->
    take_while ((<>) '\r') >>= fun chunk -> peek_char >>= function
    | Some '\r' ->
      ( advance 1 *> peek_char >>= function
          | Some '\n' ->
            write_line chunk ; advance 1 *> commit *> m
          | Some _ | None ->
            let chunk = chunk ^ "\r" in
            write_data chunk ; commit *> m )
    | Some _ | None -> write_data chunk ; commit

  let to_end_of_input_with_push ?(end_of_line = "\n")push =
    let write_data x = push (Some x) in
    let write_line x = push (Some (x ^ end_of_line)) in
    to_end_of_input ~write_data ~write_line
end

module QP = struct
  open Angstrom

  let parser ~write_data ~write_line end_of_body =
    let dec = Pecu.decoder `Manual in
    let check_end_of_body =
    let expected_len = String.length end_of_body in
      Unsafe.peek expected_len
        (fun ba ~off ~len ->
          let raw = Bigstringaf.substring ba ~off ~len in
          String.equal raw end_of_body) in

    let trailer () =
      let rec finish () = match Pecu.decode dec with
        | `Await -> assert false
        (* on [pecu], because [finish] was called just before [Pecu.src dec
          Bytes.empty 0 0] (so, when [len = 0]), semantically, it's impossible to
          retrieve this case. If [pecu] expects more inputs and we noticed end of
          input, it will return [`Malformed]. *)
        | `Data data -> write_data data ; finish ()
        | `Line line -> write_line line ; finish ()
        | `End -> commit
        | `Malformed err -> fail err

      and go () = match Pecu.decode dec with
        | `Await ->
          (* definitely [end_of_body]. *)
          Pecu.src dec Bytes.empty 0 0 ; finish ()
        | `Data data ->
          write_data data ; go ()
        | `Line line ->
          write_line line ; go ()
        | `End -> commit
        | `Malformed err -> fail err in

      go () in

    fix @@ fun m ->
    let choose chunk = function
      | true ->
        (* at this stage, we are at the end of body. We came from [`Await] case,
          so it's safe to notice to [pecu] the last [chunk]. [trailer] will
          unroll all outputs availables on [pecu]. *)
        let chunk = Bytes.sub chunk 0 (Bytes.length chunk - 1) in
        Pecu.src dec chunk 0 (Bytes.length chunk) ; trailer ()
      | false ->
        (* at this stage, byte after [chunk] is NOT a part of [end_of_body]. We
          can notice to [pecu] [chunk + end_of_body.[0]], advance on the
          Angstrom's input to one byte, and recall fixpoint until [`Await] case
          (see below). *)
        Bytes.set chunk (Bytes.length chunk - 1) end_of_body.[0] ;
        Pecu.src dec chunk 0 (Bytes.length chunk) ;
        advance 1 *> m in

    (* take while we did not discover the first byte of [end_of_body]. *)

    Unsafe.take_while ((<>) end_of_body.[0]) Bigstringaf.substring
    >>= fun chunk ->

    (* start to know what we need to do with [pecu]. *)

    let rec go () = match Pecu.decode dec with
      | `End -> commit
      | `Await ->
        (* [pecu] expects inputs. At this stage, we know that after [chunk], we
          have the first byte of [end_of_body] - but we don't know if we have
          [end_of_body] or a part of it.

          [check_end_of_body] will advance to see if we really have
          [end_of_body]. The result will be sended to [choose]. *)
        let chunk' = Bytes.create (String.length chunk + 1) in
        Bytes.blit_string chunk 0 chunk' 0 (String.length chunk) ;
        check_end_of_body >>= choose chunk'
      | `Data data ->
        write_data data ; go ()
      | `Line line ->
        write_line line ; go ()
      | `Malformed err -> fail err in
    go ()

  let with_push ?(end_of_line = "\n") ~push end_of_body =
    let write_data x = push (Some x) in
    let write_line x =
      push (Some (x ^ end_of_line)) in
    parser ~write_data ~write_line end_of_body

  let to_end_of_input ~write_data ~write_line =
    let dec = Pecu.decoder `Manual in

    fix @@ fun m -> match Pecu.decode dec with
    | `End -> commit
    | `Await ->
      (peek_char >>= function
        | None -> Pecu.src dec Bytes.empty 0 0 ; return ()
        | Some _ -> available >>= fun n -> Unsafe.take n
            (fun ba ~off ~len ->
              let chunk = Bytes.create len in
              Bigstringaf.blit_to_bytes ba ~src_off:off chunk ~dst_off:0 ~len ;
              Pecu.src dec chunk 0 len)
          >>= fun () -> m)
    | `Data data -> write_data data ; m
    | `Line line -> write_line line ; m
    | `Malformed err -> fail err

  let to_end_of_input_with_push ?(end_of_line = "\n") push =
    let write_data x = push (Some x) in
    let write_line x = push (Some (x ^end_of_line)) in
    to_end_of_input ~write_data ~write_line
end

let encoding fields =
  let encoding : Field.content_encoding option ref = ref None in
  let exception Found in
  try List.iter (function Field.Field (Encoding, v) -> encoding := Some v ; raise Found | _ -> ()) fields ; `Bit7
  with Found -> match !encoding with Some v -> v | None -> assert false

let octet ~push boundary fields : unit Angstrom.t =
  let open Angstrom in
  let not_yet_implemented = fail "not yet implemented" in

  match boundary with
  | None ->
    (match encoding fields with
     | `Quoted_printable -> QP.to_end_of_input_with_push push
     | `Base64 -> B64.to_end_of_input_with_push push
     | `Bit7 | `Bit8 | `Binary -> RAW.to_end_of_input_with_push push
     | `Ietf_token _ | `X_token _ -> not_yet_implemented) >>= fun () ->
    push None ; return ()
  | Some boundary ->
    let end_of_body = Rfc2046.make_delimiter boundary in
    (match encoding fields with
     | `Quoted_printable -> QP.with_push ~push end_of_body
     | `Base64 -> B64.with_push ~push end_of_body
     | `Bit7 | `Bit8 | `Binary -> RAW.with_push ~push end_of_body
     | `Ietf_token _ | `X_token _ -> not_yet_implemented) >>= fun () ->
    push None ; return ()

let ty fields =
  let ty = ref None in
  let exception Found in
  try List.iter (function Field.Field (Type, { ty= v; _ }) -> ty := Some v ; raise Found | _ -> ()) fields ; `Text
  with Found -> match !ty with Some v -> v | None -> assert false

let boundary fields =
  let boundary = ref None in
  let exception Found in
  try List.iter (function
      | Field.Field (Type, { parameters= vs; _ }) ->
        (match List.assoc "boundary" vs with
         | `String v | `Token v -> boundary := Some v ; raise Found
         | exception Not_found -> ())
      | _ -> ()) fields ; None
  with Found -> !boundary

let parser
  : emitters:'id emitters -> Field.field list -> 'id t Angstrom.t
  = fun ~emitters fields ->
    let open Angstrom in
    let not_yet_implemented = fail "not yet implemented" in

    let rec body parent fields =
      match ty fields with
      | `Ietf_token _x | `X_token _x -> not_yet_implemented
      | #Rfc2045.discrete ->
        let push, id = emitters fields in
        octet ~push parent fields >>| fun () -> Contents id
      | `Multipart ->
        match boundary fields with
        | Some boundary ->
          Rfc2046.multipart_body ?parent boundary (body (Option.some boundary))
          >>| List.map (fun (fields, contents) -> { fields; contents; })
          >>| fun parts -> Multipart parts
        | None -> fail "expected boundary" in

    body None fields

let parser ~emitters content_type =
  parser ~emitters [ Field.Field (Type, content_type) ]
