# Istorija izdanja

## v0.1.0

Prvo javno izdanje zajedničkog engine-a MI preduzimamo, za kompatibilnu referentnu aplikaciju zasnovanu na Decidim-u. Oznaka javnog izdanja ne mijenja internu verziju gema; distribucija ide preko Git-a i tačnog commit-a/tag-a.

- Funkcionalnosti za prijave problema, komšiluke i table, bodove, volontiranje, projekte, nenovčanu pomoć, donacije, registraciju, poruke, Milicu i administraciju.
- [Interfejsi pružalaca](docs/PROVIDER_INTERFACES.md), eksplicitna konfiguracija i sintetički primjeri, bez privatnih podataka građana ili bijeljinskih GIS skupova. Lokalni adapteri i spoljne usluge zahtijevaju zasebnu pripremu.
- Podrška za srpsku latinicu, srpsku ćirilicu, bosanski i hrvatski; [provjere engine-a i generisanog hosta](docs/PROVJERE.md) ne zavise od privatnih operativnih uputstava Fondacije.
- [AGPL-3.0-or-later](LICENSE-AGPLv3.txt), sačuvane tuđe licencne napomene i [postupak doprinosa](CONTRIBUTING.md) uz CLA.

Kompatibilnost, potrebne module i montažu provjerite prema [ugovoru engine-a](docs/ENGINE_CONTRACT.md). Lokalni testovi ne potvrđuju rad stvarnih pružalaca usluga ili produkcionu aktivaciju određene instalacije.
