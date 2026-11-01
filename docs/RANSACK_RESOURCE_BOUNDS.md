# Ransack: kompatibilnost i granice potrošnje resursa

Referentna aplikacija koristi Decidim 0.32.2 i Ransack 4.4.4 sa ugrađenim zaštitama. Engine za tu verziju koristi upstream parser bez dodavanja starog backport sloja. Zaseban backport za 4.2.1 ostaje verzijski ograničen radi kompatibilnosti; ne mijenja instalirane gemove.

Sloj ograničava položaje multiparameter polja i dubinu condition/sort ključeva prije obrade asocijacija. Obrađuje i ugniježđene hash vrijednosti: lista dozvoljenih spoljnih ključeva ili model atributa sama nije dovoljan dokaz zaštite. Relevantna upstream upozorenja su [memorijski nalaz](https://github.com/activerecord-hackery/ransack/security/advisories/GHSA-vxc9-rm8f-p56j) i [CPU nalaz](https://github.com/activerecord-hackery/ransack/security/advisories/GHSA-j3f8-w227-4hh8).

Engine uključuje zaštitu jednom pri Rails inicijalizaciji. Pregledana backport verzija je 4.2.1; poznate popravljene upstream linije koriste svoj parser (4.4.3–4.x, 5.0.2–5.x, 6.x). Za druge verzije pokretanje staje sa zahtjevom za pregled kompatibilnosti. Nakon promjene zavisnosti provjerite upozorenja i stvarni parser, umjesto uklanjanja ove provjere radi pokretanja aplikacije.

Upstream MIT obavještenje se distribuira u `lib/decidim/bih/licenses/ransack-MIT.txt`. Glavna licenca projekta ostaje navedena u korijenu repozitorijuma.

Parser regresije su u `test/lib/decidim/bih/ransack_resource_bounds_test.rb`; Rails/pretraga/tenant/javni-kalendar regresije su u `rails_test/ransack_resource_bounds_test.rb`. Koristite dokumentovan izolovani postupak provjera engine-a. Ograničeni primjeri provjeravaju granicu bez ogromnih alokacija ili zahtjeva stvarnoj instalaciji.

Skener prijavljuje stvarno zaključanu verziju gema. Provjere pokrivaju izabrani upstream ili backport režim, obične upite, granice tenant-a i neispravne ugniježđene filtere. Nemojte globalno isključivati upozorenja ili iz prolaza ovih testova zaključiti da su ostale ranjivosti otklonjene. Za produkcionu primjenu potrebni su pregled, relevantne regresije i puni propisani gate za konkretan app/engine par.
