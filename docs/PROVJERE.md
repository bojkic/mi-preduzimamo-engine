# Lokalne provjere engine-a

> Nadogradnja 2026-11-01: referentni sklop je Ruby 3.4.12, Rails 8.1.4 i Decidim 0.32.2. Istorijski rezultati ispod odnose se na tada navedene kandidate, ne dokazuju puni prolaz ovog izdanja. Vlasnik je odobrio izuzetak od punih release gate provjera; ciljane provjere i stvarno pokretanje bilježe se zasebno.

Engine nije samostalna Rails aplikacija. Za običnu instalaciju koristite kompatibilnu referentnu aplikaciju. Ovaj vodič je za doprinosioce koji provjeravaju engine u novom Decidim hostu.

## Preduslovi

Koristite Ruby 3.4.12, Node.js 22 i npm 10, PostgreSQL sa paketima za `ltree` i `pg_trgm`, Redis i sistemske biblioteke potrebne za Decidim. Instalirajte Ruby zavisnosti iz engine direktorijuma pomoću `bundle install`. Generisani host instalira sopstvene Ruby/npm zavisnosti; potreban je pristup RubyGems i npm registriju i dovoljno prostora. `BUNDLE_INSTALL_FLAGS` se prosljeđuje izričitim koracima `bundle install` za početni host i ugrađeni engine; ne sprečava generator da ranije pozove svoj Bundler.

Testove pokrećite kao neprivilegovani korisnik, u izolovanom okruženju. Ne učitavajte produkcioni `.env`, ne koristite produkcioni Redis ili bazu i ne podešavajte pristupne podatke stvarnih pružalaca za ove provjere.

## Zasebna PostgreSQL baza

Administrator jednom priprema novu testnu ulogu i praznu bazu. Primjer za lokalni PostgreSQL na Linux-u; zamijenite imena ako već postoje. Ne izvršavajte ove komande nad postojećom zajedničkom ili produkcionom bazom.

```sh
sudo -u postgres psql -v ON_ERROR_STOP=1 --dbname=postgres
```

U toj administratorskoj sesiji:

```sql
CREATE ROLE mi_oss_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
\password mi_oss_test
CREATE DATABASE mi_generated_host_test OWNER mi_oss_test;
\connect mi_generated_host_test
CREATE SCHEMA decidim_bih_extensions AUTHORIZATION postgres;
CREATE EXTENSION ltree WITH SCHEMA decidim_bih_extensions;
CREATE EXTENSION pg_trgm WITH SCHEMA decidim_bih_extensions;
REVOKE ALL ON SCHEMA decidim_bih_extensions FROM PUBLIC, mi_oss_test;
GRANT USAGE ON SCHEMA decidim_bih_extensions TO mi_oss_test;
\quit
```

Uloga za test mora imati `CREATE` na toj bazi, ali ne na šemi `decidim_bih_extensions`. Vlasništvo nad novom bazom daje prvo pravo; vlasništvo administratorske uloge nad extension šemom i navedeni grant ograničavaju drugo. U extension šemi smiju biti samo objekti ove dvije ekstenzije. Baza mora imati ime koje završava sa `_test`; `DATABASE_URL` je zabranjen u ovom harness-u.

## Rails integracioni testovi

Iz engine direktorijuma, u novom shell-u sa testnom konfiguracijom:

```sh
unset DATABASE_URL BUNDLE_GEMFILE RUBYOPT RUBYLIB
unset DECIDIM_BIH_RAILS_TEST_ENV_FILE APP_NAME
export DATABASE_HOST=127.0.0.1 DATABASE_USERNAME=mi_oss_test
read -r -s -p 'Lozinka testne baze: ' DATABASE_PASSWORD
printf '\n'
export DATABASE_PASSWORD
export DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE=mi_generated_host_test
export DECIDIM_BIH_GENERATED_HOST_REQUIRED_EXTENSIONS=ltree,pg_trgm
export REDIS_URL=redis://127.0.0.1:16379/0
export LIVE_CONTRACTS=0 INFOBIP_LIVE_SEND=0
export WORK_ROOT="$(mktemp -d)"
export KEEP_DECIDIM_BIH_RAILS_TEST=1
script/decidim_bih_rails_test
```

Redis adresa u primjeru podrazumijeva posebnu testnu instancu koju ste već pokrenuli na portu 16379. Sama promjena broja Redis baze na produkcionom portu nije izolacija. Provjera odbija nedostajuću adresu i lokalni port 6379 sa bazama 0/1. Ako je na računaru instalirana kanonska namjenska testna instanca (`/etc/mi-test-redis`), morate koristiti upravo njenu adresu, koju čitate kao ovlašćeni testni korisnik; proizvoljni port 16379 tada nije zamjena za nju. `MI_TEST_REDIS_URL_FILE` može samo dodatno ograničiti izbor instance. Izabrani testovi ne šalju stvarne poruke pružaocima.

Ista kolekcija je dostupna i kroz `bundle exec rake test:rails`. Direktna komanda iznad izbjegava naslijeđeno Bundler okruženje drugog hosta. Harness generiše novi host, instalira zavisnosti, izvršava osnovne Decidim migracije, ugrađuje lokalni engine, izvršava njegove migracije i pokreće sve `rails_test/*_test.rb`. Testni podaci ostaju u šemi sa jedinstvenom oznakom; po završetku se uklanja samo šema sa odgovarajućim markerom vlasništva. Baza i extension šema ostaju. SQL zaštite odbijaju migracije izvan testne šeme, promjene ekstenzija i privilegija. Ne koristiti proizvoljno ime `APP_NAME`: podrazumijevano ime sadrži nonce koji te zaštite očekuju.

`KEEP_DECIDIM_BIH_RAILS_TEST=1` čuva generisani direktorijum i logove za pregled greške. Nakon završetka procesa pregledajte ga i uklonite samo svoj `WORK_ROOT` kada više nije potreban. Kod nasilno prekinutog procesa provjerite i marker preostale testne šeme; nemojte brisati druge šeme ili bazu kao način čišćenja.

## Ostale provjere

`bundle exec rake test` pokreće Ruby i JavaScript kolekcije engine-a. PostgreSQL dokazi za slanje prijava zahtijevaju zasebnu praznu bazu i `MILICA_REPORT_SUBMISSION_TEST_DATABASE_URL`; ti testovi mijenjaju sopstvene testne tabele, pa ih ne usmjeravajte na bazu hosta. Opcioni JavaScript test stvarnog DOM-a koristi Chrome iz `MILICA_CHROME_BINARY`; bez te varijable ostaje evidentiran kao preskočen. Stvarne spoljne integracije zahtijevaju zasebno, izričito dogovoreno provjeravanje.

Prolaz engine kolekcije ne zamjenjuje provjere referentne aplikacije, asset build, browser tokove ili pregled privatnosti i licenci. Sačuvajte stvarne izlaze, tačne commitove i spisak preskakanja.
