# Ugovor između aplikacije i engine-a

Engine pruža ponovljive funkcionalnosti. Aplikacija upravlja domenom, organizacijom, lokalnim podacima, izvorima, identitetom, pristupnim podacima i operativnim postupkom.

## Osnovni zahtjevi

Koristite kompatibilnu verziju Decidim-a iz `lib/decidim/bih/version.rb` i module core, budgets, forms, meetings, proposals i verifications. Zaključajte tačan engine Git commit u aplikaciji i testirajte taj par.

Javni mount je `/biceriseno` po podrazumijevanim postavkama. Za drugi mount podesite `Decidim::Bih.public_mount_path`. Kratke putanje tokena `/v/:token` zahtijevaju odgovarajuću host rutu; `magic_link_short_path_enabled = false` koristi putanje unutar engine-a.

Za novi host početne datoteke pravi `bin/rails generate decidim:bih:install --mount-path=/moja-platforma --no-short-magic-links`. Pregledajte generisane inicijalizatore, assete i throttle pravila prije upotrebe.

## Konfiguracija zajednice

- Jezike postavite prije učitavanja Decidim-a: sr, sr-Cyrl, bs, hr. Ćirilicu generišite iz srpske latinice pomoću transliteratora.
- `map_default_center`, `map_default_zoom`, lokalne granice i izvori moraju pripadati vašoj zajednici. `local_address_lookup` nije obavezan.
- `public_support_name`, `public_support_email`, `public_support_address`, `public_support_website` opisuju operatera instalacije, a ne održavaoca koda.
- `public_funding_statement` je opcioni tekst ili pozivljiv izvor finansiranja vaše instalacije; bez odobrenog podatka ne navodite izmišljene donatore.
- `registration_path` i `registration_base_path` moraju biti usklađeni sa host rutama. Telefonska registracija traži konfiguraciju kanala; prije aktiviranja pregledajte `phone_first_registration_since` i ponašanje postojećih naloga.

## Obaveze hosta

Obezbijedite zaštitu javnih upisnih ruta, kontrolu ovlašćenja, pozadinske poslove, storage, odvojene testne resurse i monitoring. Ne pokrećite stvarnu dostavu u testovima. Prijem providera nije dokaz da je građanin pročitao poruku, niti je slanje prijave dokaz rješenja problema.

Podatke lokalne zajednice uvozite kroz dokumentovane interfejse i testirajte geometriju. Bodovi i trka komšiluka su priznanje angažmana; ne utiču na glasanje ili vidljivost sadržaja.

## Provjere zavisnosti i fotografija

Za Ransack kompatibilnost pogledajte [RANSACK_RESOURCE_BOUNDS.md](RANSACK_RESOURCE_BOUNDS.md), a za ImageMagick 7, prihvaćene formate i granice obrade [MEDIA_DECODING.md](MEDIA_DECODING.md). Host obezbjeđuje i ukupne procesne resurse i ograničenja zahtjeva; pojedinačni parser/dekoder test nije zamjena za propisanu provjeru cijelog izdanja.

Odoo zbir zahtijeva eksplicitni `product_ids` niz vaših pregledanih `product.template` identifikatora. Podrazumijevani niz je prazan: `call` tada ne šalje upit, a `cached` ne vraća keširani novac niti zakazuje osvježavanje. Rezultat bez datuma `as_of` nije potvrda stvarnog zbira. Sopstveni pozivalac mora zadati namespace keša i, gdje je primjenjivo, organizaciju/kampanju; host referentne aplikacije to radi iz izričite konfiguracije zajednice. Provjere zbirnih stavki naloga ne dokazuju pojedinačnu uplatu ili bankovno poravnanje.

## Katalog deklaracija razgovora

Zbir javnih read deklaracija i zaštićenih prijedloga ima konačan plafon od 40. Pojedinačni registar ostaje ograničen na 32; naziv mora biti jedinstven kroz oba registra. Ovo omogućava puni host katalog od 29 javnih alata i četiri zaštićena prijedloga. Broj deklaracija nije broj izvršenja: podrazumijevani budžet od osam poziva, rok, provjere eligible izvora i autorizovani postupci ostaju zasebni uslovi.

Regresije pokrivaju stvarni zahtjev sa 33 deklaracije, granicu 40/41, pojedinačni plafon registra, duple nazive i nepromijenjeno odbijanje devet poziva u jednom krugu.
