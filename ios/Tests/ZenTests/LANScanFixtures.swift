//  LANScanFixtures.swift
//  A real certificate, in DER, for the validity parser.
//
//  iOS has no `SecCertificateCopyValues`, so `X509Validity` walks the DER by
//  hand — and a parser tested only against a fixture somebody hand-built to
//  match it proves nothing. This is what OpenSSL actually emits:
//
//      openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
//        -days 3650 -nodes -subj "/CN=zen-test"
//      openssl x509 -in cert.pem -outform DER | base64
//
//  `openssl x509 -noout -enddate` on this one says
//  `notAfter=Sep 12 08:46:05 2036 GMT`, which is the number the test asserts.

enum LANScanFixtures {
    static let certificateExpiryYear = 2036

    static let certificateDER =
        "MIIDBzCCAe+gAwIBAgIUQ8eLPJDjT/j4cZs+xxiJrfeQuJ0wDQYJKoZIhvcNAQELBQAwEzER"
        + "MA8GA1UEAwwIemVuLXRlc3QwHhcNMjYwOTE1MDg0NjA1WhcNMzYwOTEyMDg0NjA1WjATMREw"
        + "DwYDVQQDDAh6ZW4tdGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAM2Izs2a"
        + "NS/iaDvFgkl2NRQGYLtKyE/T1YTZASLYlxdZMIqBQaSgfXWjmjmP4Y2LZf/s521bbC71vV7Z"
        + "gU+MgHIdO759+aGYvaAswwh1HFpEAA2kqCjxsAAQmIPDkjK9F44SoyewgnAumYadWwULxzDf"
        + "FHiIGg4uAqJx/zegAZ5cXk18D0FyMQ3Y+r0wDYFpQDvDjjX7IHgTqZatzUd/hIwfvltLCPRk"
        + "1HyeHpvDDtv0LgpQOY1KT/YhQtvatgzEy3SpqmlBQvKvonBb+h2WgMTpCF6aHFyPlUgRUBlu"
        + "vv3eQ/3J6cGj11X+x4EulEO0WPfqqqanUViREa48mKB/2yECAwEAAaNTMFEwHQYDVR0OBBYE"
        + "FNepSvv/FPy1T2pKnZVl+hbxd0JJMB8GA1UdIwQYMBaAFNepSvv/FPy1T2pKnZVl+hbxd0JJ"
        + "MA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAIsqiDECN9AJcwEgdB0c+yQ1"
        + "K07LjNij3dWuQ5VwInTcnbRj7AkRo2eUBynN6lZ1wkKDgh5MYADbPzwcU/GEDOJ047cCoD1x"
        + "O97TT8x3tXG7s7zQxnN9CUJFOf+/W/KyVsaP8/TSFWK7RfULQ8xaiCjh7GzPbpur0HkYrdsH"
        + "JQt/mXAI97nRcKFPnth933/NevFlo8Qi7YdAJw9Gw9WiJWhq4jMSYOVtmOWY716MEVLAndXB"
        + "7S0Cc6S5XvIw3PKmEvujsXRcxgCHIMnxVsy6vOzHEsQWQM3XTtWt7Yw3y7M0qQL5Bul+mn13"
        + "2QdI7u18Or5Odp0ssUB7bH3PJ+9kgmA="
}
