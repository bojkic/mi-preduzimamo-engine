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


## Rok potvrde telefona i granica callback-a

BIH potvrda broja telefona zadržava postojeći rok `LoginToken::VERIFY_TTL` od 24 sata, za verifikacioni link i njegov kod. Prijava bez lozinke zadržava zasebnih 10 minuta. `PhoneVerification::ConfirmAuthorization` nasljeđuje stvarnu upstream komandu: mijenja samo provjeru roka za BIH SMS potvrdu, bez globalne promjene Decidim podešavanja. Zaključavanje, brojanje pokušaja, validacija i grant ostaju upstream. Drugi workflow-i koriste upstream rok.

Posebno ponoviti `phone_verification_complete_test.rb`, `one_step_registration_flow_test.rb`, `simplified_registration_test.rb`, `awards_after_verification_test.rb` i postojeći negativni obuhvat. Potvrda unutar 24 sata mora raditi i nakon isteka kraćeg upstream podrazumijevanog roka; poslije BIH roka i tokom zaključavanja mora biti odbijena. Ne prepravljati timestamp ili token radi prolaza.

Grant i upstream reset brojača predstavljaju dva save-a u jednoj transakciji. Bodovi i drugi prvi-grant efekti smiju nastati tek nakon commita, uz sačuvan prvobitni prelaz i poštanske metadata podatke. Rollback, rollback ugniježđenog savepoint-a, ponovno snimanje i obnova postojećeg granta ne smiju dati duple ili prerane efekte. Spisak testova se dopunjuje; nefiltrirana podrazumijevana kolekcija ostaje obavezna za tvrdnju o punom prolazu.


## DB-free provjere i razvojni bundle

Engine `Gemfile` uključuje `decidim-participatory_processes` za stvarne upstream locale fajlove i Sidekiq 7.3 za test stvarnog error logger-a. To su razvojne/testne zavisnosti; runtime engine-a ne nameće Sidekiq hostu. Pripremite ovaj engine bundle i pokrenite `bundle check` prije Ruby unit provjera. Normalni generated-host manifest ne mora imati Sidekiq, zato se prošireni logger unit obuhvat pokreće iz engine razvojnog bundle-a, a ne iz proizvoljnog generisanog host bundle-a. Za kompletan Ruby/JavaScript obuhvat služi `bundle exec rake test`; dokumentovani Rails launcher je zaseban obuhvat.

Poštanski callback dešifruje snimljene metadata vrijednosti tek nakon commita pomoću upstream `RecordEncryptor`. `saved_changes` sadrži šifrovane vrijednosti, pa jednostavna privremena AR tabela bez tog concern-a nije potpuna regresija. Native test mora dokazati da je stored atribut zaista šifrovan, da geokoder dobija stvarnu fixture adresu nakon commita i da metadata na dodijeljenoj autorizaciji ostaje obrisana.

Proširena unit grupa sa script/database-isolation fixture testovima zahtijeva eksplicitni dozvoljeni test `REDIS_URL` za provjeru guard-a; to nije runtime Redis i ti shell doubles ne dokazuju stvarni Redis/DB prolaz. Četiri nove čiste Ruby regresije iz nezavisnog izvještaja nemaju DB/Redis preduslov. Sačuvati te različite obuhvate u izvještaju.
