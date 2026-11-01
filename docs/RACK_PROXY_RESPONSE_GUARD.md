# Odgovori rack-proxy0.8.3

Engine privremeno štiti odgovore instalirane verzije0.8.3: odbija istovremeni Transfer-Encoding i Content-Length sa502, zatvara već pokrenutu streaming sesiju bez čitanja odbijenog tijela i uklanja response zaglavlja navedena u Connection polju. Ne mijenja konfiguraciju backend-a, zahtjeve, status uspješnog odgovora ili način predstavljanja tijela.

[Upstream GHSA-42qh-8mx8-7wqm](https://github.com/ncr/rack-proxy/security/advisories/GHSA-42qh-8mx8-7wqm) potvrđuje1.0.0–1.0.2, a starije verzije izričito ostavlja neocijenjenim. Instalirani0.8.3 ima sličan obrazac obrade zaglavlja; ova zaštita nije tvrdnja da je konkretan server dokazano iskoristiv ili da je cijeli paket provjeren. Primjenjuje se samo na0.8.3; pri nadogradnji ponovo pregledati upstream, zavisnosti i testove.

Standalone regresije koriste stvarni Rack::Proxy i njegov streaming adapter uz kontrolisani Net::HTTP/backend dubl bez mreže. Rails harness zasebno provjerava initializer i Shakapacker pass-through. To nije provjera ponašanja stvarnog frontend servera, mreže ili produkcionog middleware lanca. Pripremljene testove treba izvršiti nad tačnim kandidatom; sama prisutnost zaštite nije završen bezbjednosni gate. Razvojni asset server ne izlagati javnoj mreži.
