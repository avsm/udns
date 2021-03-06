(* (c) 2018 Hannes Mehnert, all rights reserved *)

open Mirage_types_lwt

open Lwt.Infix

let src = Logs.Src.create "dns_mirage_resolver" ~doc:"effectful DNS certify"
module Log = (val Logs.src_log src : Logs.LOG)

module Make (R : RANDOM) (P : PCLOCK) (TIME : TIME) (S : STACKV4) = struct

  module Dns = Dns_mirage.Make(S)

  module U = S.UDPV4
  module T = S.TCPV4

  let letsencrypt_ca =
    let pem = {|-----BEGIN CERTIFICATE-----
MIIEkjCCA3qgAwIBAgIQCgFBQgAAAVOFc2oLheynCDANBgkqhkiG9w0BAQsFADA/
MSQwIgYDVQQKExtEaWdpdGFsIFNpZ25hdHVyZSBUcnVzdCBDby4xFzAVBgNVBAMT
DkRTVCBSb290IENBIFgzMB4XDTE2MDMxNzE2NDA0NloXDTIxMDMxNzE2NDA0Nlow
SjELMAkGA1UEBhMCVVMxFjAUBgNVBAoTDUxldCdzIEVuY3J5cHQxIzAhBgNVBAMT
GkxldCdzIEVuY3J5cHQgQXV0aG9yaXR5IFgzMIIBIjANBgkqhkiG9w0BAQEFAAOC
AQ8AMIIBCgKCAQEAnNMM8FrlLke3cl03g7NoYzDq1zUmGSXhvb418XCSL7e4S0EF
q6meNQhY7LEqxGiHC6PjdeTm86dicbp5gWAf15Gan/PQeGdxyGkOlZHP/uaZ6WA8
SMx+yk13EiSdRxta67nsHjcAHJyse6cF6s5K671B5TaYucv9bTyWaN8jKkKQDIZ0
Z8h/pZq4UmEUEz9l6YKHy9v6Dlb2honzhT+Xhq+w3Brvaw2VFn3EK6BlspkENnWA
a6xK8xuQSXgvopZPKiAlKQTGdMDQMc2PMTiVFrqoM7hD8bEfwzB/onkxEz0tNvjj
/PIzark5McWvxI0NHWQWM6r6hCm21AvA2H3DkwIDAQABo4IBfTCCAXkwEgYDVR0T
AQH/BAgwBgEB/wIBADAOBgNVHQ8BAf8EBAMCAYYwfwYIKwYBBQUHAQEEczBxMDIG
CCsGAQUFBzABhiZodHRwOi8vaXNyZy50cnVzdGlkLm9jc3AuaWRlbnRydXN0LmNv
bTA7BggrBgEFBQcwAoYvaHR0cDovL2FwcHMuaWRlbnRydXN0LmNvbS9yb290cy9k
c3Ryb290Y2F4My5wN2MwHwYDVR0jBBgwFoAUxKexpHsscfrb4UuQdf/EFWCFiRAw
VAYDVR0gBE0wSzAIBgZngQwBAgEwPwYLKwYBBAGC3xMBAQEwMDAuBggrBgEFBQcC
ARYiaHR0cDovL2Nwcy5yb290LXgxLmxldHNlbmNyeXB0Lm9yZzA8BgNVHR8ENTAz
MDGgL6AthitodHRwOi8vY3JsLmlkZW50cnVzdC5jb20vRFNUUk9PVENBWDNDUkwu
Y3JsMB0GA1UdDgQWBBSoSmpjBH3duubRObemRWXv86jsoTANBgkqhkiG9w0BAQsF
AAOCAQEA3TPXEfNjWDjdGBX7CVW+dla5cEilaUcne8IkCJLxWh9KEik3JHRRHGJo
uM2VcGfl96S8TihRzZvoroed6ti6WqEBmtzw3Wodatg+VyOeph4EYpr/1wXKtx8/
wApIvJSwtmVi4MFU5aMqrSDE6ea73Mj2tcMyo5jMd6jmeWUHK8so/joWUoHOUgwu
X4Po1QYz+3dszkDqMp4fklxBwXRsW10KXzPMTZ+sOPAveyxindmjkW8lGy+QsRlG
PfZ+G6Z6h7mjem0Y+iWlkYcV4PIWL1iwBi8saCbGS5jN2p8M+X+Q7UNKEkROb3N6
KOqkqm57TH2H3eDJAkSnh6/DNFu0Qg==
-----END CERTIFICATE-----|}
    in
    X509.Encoding.Pem.Certificate.of_pem_cstruct1 (Cstruct.of_string pem)

  let dns_header () =
    let id = Randomconv.int16 R.generate in
    { Dns_packet.id ; query = true ; operation = Dns_enum.Query ;
      authoritative = false ; truncation = false ; recursion_desired = false ;
      recursion_available = false ; authentic_data = false ; checking_disabled = false ;
      rcode = Dns_enum.NoError }

  let nsupdate_csr flow pclock hostname keyname zone dnskey csr =
    let tlsa =
      { Dns_packet.tlsa_cert_usage = Dns_enum.Domain_issued_certificate ;
        tlsa_selector = Dns_enum.Tlsa_selector_private ;
        tlsa_matching_type = Dns_enum.Tlsa_no_hash ;
        tlsa_data = X509.Encoding.cs_of_signing_request csr ;
      }
    in
    let nsupdate =
      let zone = { Dns_packet.q_name = zone ; q_type = Dns_enum.SOA }
      and update = [
        Dns_packet.Remove (hostname, Dns_enum.TLSA) ;
        Dns_packet.Add ({ Dns_packet.name = hostname ; ttl = 600l ; rdata = Dns_packet.TLSA tlsa })
      ]
      in
      { Dns_packet.zone ; prereq = [] ; update ; addition = [] }
    and header =
      let hdr = dns_header () in
      { hdr with Dns_packet.operation = Dns_enum.Update }
    in
    let now = Ptime.v (P.now_d_ps pclock) in
    match Dns_tsig.encode_and_sign ~proto:`Tcp header (`Update nsupdate) now dnskey keyname with
    | Error msg -> Lwt.return_error msg
    | Ok (data, mac) ->
      Dns.send_tcp (Dns.flow flow) data >>= function
      | Error () -> Lwt.return_error "tcp send err"
      | Ok () -> Dns.read_tcp flow >>= function
        | Error () -> Lwt.return_error "tcp recv err"
        | Ok data ->
          match Dns_tsig.decode_and_verify now dnskey keyname ~mac data with
          | Error e -> Lwt.return_error ("nsupdate reply " ^ e)
          | Ok _ -> Lwt.return_ok ()

  let query_certificate flow public_key q_name =
    let good_tlsa tlsa =
      if
        tlsa.Dns_packet.tlsa_cert_usage = Dns_enum.Domain_issued_certificate
        && tlsa.Dns_packet.tlsa_selector = Dns_enum.Tlsa_full_certificate
        && tlsa.Dns_packet.tlsa_matching_type = Dns_enum.Tlsa_no_hash
      then
        match X509.Encoding.parse tlsa.Dns_packet.tlsa_data with
        | Some cert ->
          let keys_equal a b =
            Cstruct.equal (X509.key_id a) (X509.key_id b)
          in
          if keys_equal (X509.public_key cert) public_key then
            Some cert
          else
            None
        | _ -> None
      else
        None
    in
    let header = dns_header ()
    and question = { Dns_packet.q_name ; q_type = Dns_enum.TLSA }
    in
    let query = { Dns_packet.question = [ question ] ; answer = [] ; authority = [] ; additional = [] } in
    let buf, _ = Dns_packet.encode `Tcp header (`Query query) in
    Dns.send_tcp (Dns.flow flow) buf >>= function
    | Error () -> Lwt.fail_with "couldn't send tcp"
    | Ok () ->
      Dns.read_tcp flow >>= function
      | Error () -> Lwt.fail_with "couldn't read tcp"
      | Ok data ->
        match Dns_packet.decode data with
        | Ok ((header, `Query q, _, _), _) ->
          (* collect TLSA pems *)
          let tlsa =
            List.fold_left (fun acc rr -> match rr.Dns_packet.rdata with
                | Dns_packet.TLSA tlsa ->
                  begin match good_tlsa tlsa with
                    | None -> acc
                    | Some cert -> Some cert
                  end
                | _ -> acc)
              None q.Dns_packet.answer
          in
          Lwt.return tlsa
        | Ok ((_, v, _, _), _) ->
          Log.err (fun m -> m "expected a response, but got %a"
                       Dns_packet.pp_v v) ;
          Lwt.return None
        | Error e ->
          Log.err (fun m -> m "error %a while decoding answer"
                       Dns_packet.pp_err e) ;
          Lwt.return None

  let initialise_csr hostname seed =
    let private_key =
      let seed = Cstruct.of_string seed in
      let g = Nocrypto.Rng.(create ~seed (module Generators.Fortuna)) in
      Nocrypto.Rsa.generate ~g 4096
    in
    let public_key = `RSA (Nocrypto.Rsa.pub_of_priv private_key) in
    let csr = X509.CA.request [`CN hostname ] (`RSA private_key) in
    (private_key, public_key, csr)

  let query_certificate_or_csr flow pclock pub hostname keyname zone dnskey csr =
    query_certificate flow pub hostname >>= function
    | Some certificate ->
      Log.info (fun m -> m "found certificate in DNS") ;
      Lwt.return certificate
    | None ->
      Log.info (fun m -> m "no certificate in DNS, need to transmit the CSR") ;
      nsupdate_csr flow pclock hostname keyname zone dnskey csr >>= function
      | Error msg ->
        Log.err (fun m -> m "failed to nsupdate TLSA %s" msg) ;
        Lwt.fail_with "nsupdate issue"
      | Ok () ->
        let rec wait_for_cert () =
          query_certificate flow pub hostname >>= function
          | Some certificate ->
            Log.info (fun m -> m "finally found a certificate") ;
            Lwt.return certificate
          | None ->
            Log.info (fun m -> m "waiting for certificate") ;
            TIME.sleep_ns (Duration.of_sec 1) >>= fun () ->
            wait_for_cert ()
        in
        wait_for_cert ()

  let retrieve_certificate stack pclock ~dns_key ~hostname ~key_seed dns port =
    let keyname, zone, dnskey =
      match Astring.String.cut ~sep:":" dns_key with
      | None -> invalid_arg "couldn't parse dnskey"
      | Some (name, key) ->
        match Domain_name.of_string ~hostname:false name, Dns_packet.dnskey_of_string key with
        | Error _, _ | _, None -> invalid_arg "failed to parse dnskey"
        | Ok name, Some dnskey ->
          let zone = Domain_name.drop_labels_exn ~amount:2 name in
          (name, zone, dnskey)
    in
    let hostname = Domain_name.prepend_exn zone hostname in

    let priv, pub, csr = initialise_csr (Domain_name.to_string hostname) key_seed in
    S.TCPV4.create_connection (S.tcpv4 stack) (dns, port) >>= function
    | Error e ->
      Log.err (fun m -> m "error %a while connecting to name server, shutting down" S.TCPV4.pp_error e) ;
      Lwt.fail_with "couldn't connect to name server"
    | Ok flow ->
      let flow = Dns.of_flow flow in
      query_certificate_or_csr flow pclock pub hostname keyname zone dnskey csr >>= fun certificate ->
      S.TCPV4.close (Dns.flow flow) >|= fun () ->
      `Single ([certificate ; letsencrypt_ca], priv)
end
