# Dokumentacija zajedničkog engine-a

[README engine-a](../README.md) opisuje ugradnju i osnovne komande. Prvu instalaciju pokrenite kroz kompatibilnu referentnu aplikaciju; engine nije samostalna Rails aplikacija.

| Oblast | Dokument |
|---|---|
| Promjene po izdanjima | [Istorija izdanja](../CHANGELOG.md). |
| Testna baza, Redis i generisani host | [Lokalne provjere engine-a](PROVJERE.md). |
| Odnos host aplikacije i engine-a | [Engine ugovor](ENGINE_CONTRACT.md). |
| Spoljni pružaoci i integracije | [Interfejsi pružalaca](PROVIDER_INTERFACES.md). |
| Identitet i ilustracije zajednice | [Zamjena brenda i asseta](BRAND_ASSET_REPLACEMENT.md). |
| Pregled privatnosti i njegov obuhvat | [Ugovor pregleda privatnosti](PRIVACY_AUDIT_CONTRACT.md). |
| Obrada slika i resursni limiti | [Dekodiranje medija](MEDIA_DECODING.md). |
| Ograničavanje Ransack ulaza | [Resursne granice Ransack-a](RANSACK_RESOURCE_BOUNDS.md). |
| Privremena zaštita kompatibilne proxy verzije | [Rack proxy odgovori](RACK_PROXY_RESPONSE_GUARD.md). |

Dokumenti o zaštitama opisuju konkretne mehanizme i njihove granice. Za svoju instalaciju provjerite tačne verzije, konfiguraciju i rezultate testova; prisustvo vodiča ili testa ne znači završen bezbjednosni pregled.

Za izmjene i prijave pogledajte [AGENTS.md](../AGENTS.md), [doprinose](../CONTRIBUTING.md), [pravila ponašanja](../CODE_OF_CONDUCT.md) i [privatno prijavljivanje bezbjednosnih problema](../SECURITY.md).

Sačuvajte [licencu](../LICENSE-AGPLv3.txt), [autorske napomene](../COPYRIGHT.md) i [napomene za assete](../public/ASSET_NOTICE.md). Prava na sopstvene sadržaje, kontakte i geografske podatke uređuju se zasebno.
