# R-03b — upload obu plików udany, przypięcie niezaliczone

Po odpowiedzi właściciela „zgoda” wykonano dokładnie jeden [zatwierdzony przebieg](ZAKRES_PROBY_PLIKOW_DEVELOPMENT.md), inwentarz `e0e82749…`, kod `d9d5706`. Proces zakończył się kodem 3, permit usunięto, attempt i prywatne dowody zachowano. Nie ponawiano uploadu, rekordu ani okna.

- Oba granty i oba uploady do `cws.icloud-content.com` zostały przyjęte. Produkcyjny kod zweryfikował i zaszyfrował receipty dla 1649 B oraz 1104 B, łącznie 2753 B.
- Tworzenie `EchoesAvatarV1` z tymi assetami zwróciło **HTTP 400** (JSON/gzip) na `records/modify`. Nie zapisano treści błędu, więc dokładna przyczyna pozostaje nieznana. Odbiór zatrzymał się w stage; nie wykonano pobierania ani późniejszej próby konfliktu CAS.
- Wykonano 28 żądań API (w tym 2 granty) i 2 uploady; 0 pobrań. Wszystkie dotyczyły dokładnego losowego inwentarza. Checkpoint używał własnej nazwy trial, globalnego checkpointu nie dotykano.
- Sprzątanie potwierdzone: świeży lookup avatara dał NOT_FOUND, własny checkpoint usunięto warunkowo i na końcu oba rekordy były NOT_FOUND. Brak oczekującego IO. **Nie jest to dowód fizycznego usunięcia dwóch nieprzypiętych plików z Apple/CDN**; mogą pozostać po stronie dostawcy. Lokalne zaszyfrowane dowody także zachowano.

[Publiczny wynik i hashe prywatnych dowodów](evidence/avatar-assets-first-development-results.json). Bez telefonu, danych użytkowników, Cloudflare, zmian Production, nowych ról/kluczy lub opłat.

## Poprawka lokalna i granice wnioskowania

W [oficjalnym przykładzie Apple](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html) pola assetów mają sam słownik `value`, bez opcjonalnego `type`. Nasz builder wysyłał dodatkowe `type: ASSET`, będące wewnętrznym znacznikiem. Przed poprawką nowy test z rygorystycznym modelem tej postaci zapisu odrzucił create. Builder emituje teraz postać z przykładu; wszystkie kontrole manifestu, receiptów i własności pozostają w działających komponentach. To **hipoteza naprawy HTTP 400**, nie rozpoznana treść rzeczywistego błędu.

Operator czyta teraz także ograniczone JSON błędu (16 KiB/64 fragmenty/8 s) i zapisuje wyłącznie zamknięty kod oraz heurystyczną kategorię: asset_type, asset_receipt, schema_field, other albo unreadable. Bez free-form reason, tokenów, URL, receiptów i body. Dodano zakaz następnego żądania podczas nieodprowadzonego konkretnego IO. Pierwszy pełny run wykrył w modelu retencji wymaganie etykiety ASSET; zastąpiono je porównaniem całego rekordu ze snapshotem sprzed retencji i sprawdzeniem obecności assetów/czytelności.

Weryfikacja końcowa: **1014/1014** na Node 22.23.5 i 24.22.3, 0 skipów; 43 testy skupione oraz 4 testy retencji workerd; 5 kontroli składni. Rzeczywisty nieaktywny pakiet backendu zbudowany, bez wdrożenia. Trzy nowe testy obejmują postać zapisu i nieujawnianie/ograniczanie błędów. Dostawca i tożsamość w lokalnych testach są modelowane. Poprawki nie wysłano jeszcze do Apple w nowym przebiegu.

Następny krok: [nowa seria najwyżej dwóch odrębnych prób](ZAKRES_SERII_PLIKOW_DEVELOPMENT.md) w jednym wspólnym oknie do 30 minut. Zatrzymanie po pierwszym sukcesie albo po niepełnym sprzątaniu/niepewnym IO. Dopuszcza lokalne poprawki formatu/diagnostyki w niezmienionym budżecie; nowa zgoda jest konieczna, ponieważ dotychczasowa obejmowała jeden zakończony przebieg. Brak zgody, permitów, attempt i rozpoczętego okna nowej serii. Pełny R-03 oraz migracja nadal otwarte.
