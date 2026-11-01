# Interfejsi lokalnih i spoljnih usluga

Povezivanje host adaptera je eksplicitno. Referentna instalacija nema podrazumijevane bijeljinske primaoce, naloge, GIS podatke ili aktivne lokalne adaptere.

- `Decidim::Bih.concierge_resolver`: objekat odgovora ili pozivljivi resolver koji ga vraća. `nil` znači da lokalni razgovorni adapter nije konfigurisan. Podesite tek nakon provjere lokalnih izvora i privatnosti.
- `Decidim::Bih.donations_provider`: host izvor projekata i zbirnih donacija. Bez providera javna površina ne smije predstavljati podatke druge zajednice kao svoje.
- `Decidim::Bih.city_data_freshness_provider`: opcioni provider sa `statuses(organization:)` za status lokalnih izvora.
- `Decidim::Bih.city_data_preview_provider`: opcioni provider sa `previews(organization:, waste_query:, parking_query:, budget_query:, locale:)` za administratorski pregled.
- `Decidim::Bih.local_address_lookup`: opcioni pozivljivi adapter sa `query:` i `organization:`. Geokodiranje zahtijeva odabrani servis, identitet operatera i poštovanje njegovih ograničenja.

Infobip kanali zahtijevaju sopstvene pristupne podatke, odobrene pošiljaoce, šablone i autentifikovane webhooks. Viber Business Messages i Viber Bot imaju različite identifikatore i ne zamjenjuju jedan drugog. Messenger/Instagram nisu zamjena za telefonsku autentifikaciju.

Gemini/Vertex i lokalni izvori koriste se samo prema konfiguraciji instalacije. Provjerite koje podatke šaljete pružaocu usluge, dozvoljene svrhe, saglasnost i čuvanje. Ne stavljajte privatne razgovore u evaluacione korpuse ili Git.

Slanje e-maila lokalnoj službi zahtijeva konfigurisan transport, primaoca i povratno sanduče. Bez toga dostava ostaje neaktivna ili jasno odbijena; ne vraćajte tuđe adrese kao zamjensku vrijednost. Neizvjesnu isporuku ne proglašavajte uspješnom i ne ponavljajte je bez provjere.

Testovi adaptera koriste izmišljene podatke i presretanje zahtjeva. Stvarno prihvatanje usluge/provajdera vodi se kao poseban dokaz.
