# Provjera engine-a iz javnog klona

Ovo je razvojna provjera, odvojena od instalacije zajednice i od produkcionog servera. Koristite poseban Linux/WSL nalog i test PostgreSQL/Redis, bez produkcionog env-a, baze, upload-a ili naloga. Sam prolaz fixture testova nije Docker/worker/browser prihvatanje.

## Preduslovi

Ruby i Node biraju se prema `.ruby-version` i `.node-version` javnog para. Na Ubuntu-u su za native gem-ove potrebni razvojni alati i biblioteke, uključujući `build-essential`, `libyaml-dev`, `libpq-dev`, `libicu-dev`, `libvips`, `pkg-config`, Git i npm. Minimalni runtime image namjerno nema sve te alate; njega ne mijenjajte u razvojni host. Potrebni su izvršiv Decidim generator, upisiv privatni Bundler cache, dovoljno diska i pristup javnim registry izvorima. Browser provjera dodatno zahtijeva kompatibilan Chrome/driver i stvarno izgrađene test resurse.

DB administrator prvo priprema **novu praznu test bazu**, npr. `mi_platform_test`, namjensku LOGIN rolu bez SUPERUSER/CREATEDB/CREATEROLE, vlasništvo te test baze i `ltree`/`pg_trgm` u šemi `decidim_bih_extensions`. Nalog smije praviti svoje privremene šeme samo u toj test bazi. Ekstenzije u `public` ili produkciona baza nisu zamjena; launcher to odbija. Lozinku postavite privatno, ne u javnoj komandi ili izvještaju.

Postavite sopstvene `DATABASE_HOST`, `DATABASE_USERNAME` i privatni `DATABASE_PASSWORD`, a ime kroz `DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE=mi_platform_test`. `DATABASE_URL` mora biti uklonjen. `REDIS_URL` mora označavati zaseban test Redis, ne aplikacioni/produkcioni db0/db1. Kada host ima namjenski test Redis credential fajl, važi njegov stroži resolver. Ovi preduslovi ne daju aplikaciji trajna superuser prava.

## Pokretanje

U engine klonu pripremite njegov bundle. Po potrebi postavite `BUNDLE_PATH` na sopstveni upisivi razvojni cache. Launcher generiše zaseban host, postavlja Ransack 4.4.4 i Minitest ~>5.27 prema podržanom paru, pa rješava njegov bundle. Ne uređujte generisani Gemfile ili launcher ručno radi prolaza. Naslijeđeni Gemfile/frozen/local bundle config i Bundler preload se odvajaju od tog hosta; eksplicitni cache ostaje dostupan.

```sh
unset DATABASE_URL
export DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE=mi_platform_test
# Ostale test DB/Redis vrijednosti prethodno postaviti privatno.
script/decidim_bih_rails_test
```

Podrazumijevani obuhvat je cijela engine Rails kolekcija. Za ciljanu dijagnostiku podržan je eksplicitni izbor postojećih basenames, bez mijenjanja skripte:

```sh
DECIDIM_BIH_RAILS_TEST_FILES='email_confirmation_flow_test.rb phone_first_registration_test.rb onboarding_next_step_test.rb'   script/decidim_bih_rails_test
```

Takav rezultat je samo rezultat izabranih fajlova. Podrška uključuje sr, sr-Cyrl, bs, hr i en za razvojne fixture-e. SQL/search-path/extension zaštite ostaju uključene; automatski post-migration schema dump isključen je samo u generisanom izolovanom schema fixture-u, jer mijenja search_path. Primijenjene migracije se i dalje provjeravaju.

`APP_NAME` podrazumijevano dobija jedinstveno ime. Postojeći host ili npm-wrapper direktorijum odbija se i čuva, uključujući EXIT cleanup. Ne koristite isto ime da prepišete raniju probu. `KEEP_DECIDIM_BIH_RAILS_TEST=1` čuva novogenerisani radni direktorijum radi dijagnostike; čuvanje direktorijuma nije obećanje da je njegova privremena DB šema ostala poslije cleanup-a. Izvještaj treba da sadrži stvarne verzije, source SHA, izabrani obuhvat, prve greške i završne rezultate, bez tajni.

## Regresije za završni instalacioni kandidat

Provjeriti confirmation mail sa namespaced-only `_prefixes`, stvarnu worker/Mailpit dostavu nove adrese, neizmijenjeni lokalni proof link sa ispravnim portom i praćenje povratne SMS/prijavne rute. Potvrda adrese ne smije zaobići lozinku, OTP, izbor zajednice ili proof provjere. Rails mail-job logging skriva argumente i za ranije default mail poslove; Sidekiq error context se rediguje bez promjene izvršnih/retry argumenata.

Dodatno provjeriti editor/Publish/Update/Phases i uppercase validacioni tekst na sva četiri jezika, `%level%`/`%position%` interpolacije, datum i timezone/DST granice kroz stvarno montirane rute. Za demo geografiju zasebno provjeriti eksplicitni import, ponavljanje i odbijanje postojeće geografije. Svi ovi testovi pripadaju novom kandidatu; RC6 dijagnostički prolazi se ne prenose automatski.
