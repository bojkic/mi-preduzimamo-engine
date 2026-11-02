# Istorija izdanja

## v0.1.3 — 2026-11-02

- Ispravljen poziv Decidim 0.32 komande za telefonsku i imenovanu/poštansku autorizaciju; privremeni host adapter nije potreban.

## v0.1.2 — 2026-11-01

- Dodata kompaktna komponenta javnih aktivnosti za glavni meni Decidim-a 0.32, uz postojeće provjere vidljivosti i odvojenu keš memoriju.

## v0.1.1

- BIH administracija koristi jezičke putanje Decidim-a 0.32; stari GET linkovi vode do dostupne stranice, a raniji POST/PATCH endpoint-i ostaju kompatibilni.
- Usklađene su provjere jezičkih putanja i linkova prijava, uz zadržanu provjeru obrade prijava i ovlašćenja.

## v0.1.0

Prvo javno izdanje zajedničkog engine-a MI preduzimamo, za kompatibilnu referentnu aplikaciju zasnovanu na Decidim-u. Oznaka javnog izdanja ne mijenja internu verziju gema; distribucija ide preko Git-a i tačnog commit-a/tag-a.

- Funkcionalnosti za prijave problema, komšiluke i table, bodove, volontiranje, projekte, nenovčanu pomoć, donacije, registraciju, poruke, Milicu i administraciju.
- [Interfejsi pružalaca](docs/PROVIDER_INTERFACES.md), eksplicitna konfiguracija i sintetički primjeri, bez privatnih podataka građana ili bijeljinskih GIS skupova. Lokalni adapteri i spoljne usluge zahtijevaju zasebnu pripremu.
- Podrška za srpsku latinicu, srpsku ćirilicu, bosanski i hrvatski; [provjere engine-a i generisanog hosta](docs/PROVJERE.md) ne zavise od privatnih operativnih uputstava Fondacije.
- [AGPL-3.0-or-later](LICENSE-AGPLv3.txt), sačuvane tuđe licencne napomene i [postupak doprinosa](CONTRIBUTING.md) uz CLA.

Kompatibilnost, potrebne module i montažu provjerite prema [ugovoru engine-a](docs/ENGINE_CONTRACT.md). Lokalni testovi ne potvrđuju rad stvarnih pružalaca usluga ili produkcionu aktivaciju određene instalacije.
