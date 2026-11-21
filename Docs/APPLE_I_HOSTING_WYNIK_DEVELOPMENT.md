# R-04b — logowanie Apple i nieaktywny backend: wynik

21 listopada 2026. Wykonano konkretny zakres zatwierdzony dla commitu `15ff4ac`; pełna migracja pozostaje w realizacji. [Publiczny raport z SHA i identyfikatorami](evidence/apple-signin-inactive-deployment-acceptance.json).

## Wykonane zmiany

- Apple Developer, zespół `22YC9RAP4P`: zapisano Sign in with Apple jako primary dla `mpvEcho.Echo`. Po ponownym otwarciu App ID zaznaczenie i primary są zapisane, Save nieaktywne. Apple uprzedziło o unieważnieniu dotychczasowych profili dla przyszłego podpisywania; nie wygenerowano profilu ani nie instalowano aplikacji.
- Zarejestrowano jeden klucz `QPBMSAY553`, wyłącznie Sign in with Apple i primary Echoes. Apple nie dopuszcza myślników w nazwie, dlatego użyto `Echoes Sign in with Apple 20261121`. Klucz pobrano raz, przeniesiono po porównaniu do prywatnego pliku0600/katalogu0700 poza repo i aplikacją; kopię z Downloads usunięto po weryfikacji. Publiczny SPKI SHA `0676ced4f6ae6ec4e822b24d88dc25317c527709e2a09338006a68d00515e377`. Istniejąca klasa AppleClientSecret podpisała i lokalnie zweryfikowała ES256/P1363 dla prawdziwego klucza na obu Node22/24, bez sieci lub zachowania JWT. To nie jest odbiór OAuth Apple.
- Na potwierdzonym WorkersFree utworzono `echoes-community-development`. Panel wymagał początkowego Hello World; zatwierdzony dokument dopuszczał dokładnie ten przypadek. Wyłączono workers.dev/preview i domyślne logi przed wgraniem backendu. Istniejąca diagnostyka pozostała bez zmian.
- Utworzono najwyżej jeden token `Individual Workers Editor`, ograniczony do nowej usługi; zakres sprawdzono przed utworzeniem i w panelu tokenu. Jedno PUT przyjęło dokładny nieaktywny pakiet z R-04a, dwa Wasm, licencje oraz migrację `community-v1/new_sqlite_classes=[CommunityAuthority]`. Powstał binding `COMMUNITY_AUTHORITY`, namespace `c56ebf43cfc246edb56e6615987b4c57`.
- Odczyt konfiguracji potwierdził wszystkie wartości zgodne z przygotowanym metadata, wszystkie flagi0, brak secret bindings, termin pusty, CloudKit wyłącznie Development i oba publiczne URL wyłączone. Odczyt aktywnej wersji `3a7ada53-3000-4c70-a8bb-30f49c59b670` potwierdził `community-v1`, datę2026-11-14 i oba compatibility flags. Deployment `9270f237-06fc-4d72-bec8-741794acc91c` kieruje100% do tej wersji; bez publicznej trasy nie jest to aktywacja użytkowników.
- Pobranie rzeczywistych modułów i binarne porównanie potwierdziły identyczne długości/SHA kodu, dwóch Wasm i licencji. Token wdrożeniowy usunięto w panelu po użyciu; jeden końcowy odczyt nim odmówił401/code10000. Jego lokalny plik został usunięty.

## Problemy kontroli, które rozwiązano

Automatyczna kontrola pierwszego kliknięcia Deploy odrzuciła domyślne Hello World jako rzekomo spoza zakresu. Sprawdzono treść zatwierdzonego dokumentu15ff4ac dopuszczającą to stałe powitanie na dokładnym adresie i kod bez danych; ponowienie tego samego kroku zostało przyjęte. Nie rozszerzano zgody ani nie obchodzono kontroli innym kanałem.

Pomocnicze skrypty odbioru początkowo oczekiwały obecności wyłączonego observability i migration_tag w settings; API pomija pierwsze, drugie udostępnia na wersji. GET/content odmówił405; poprawny dokumentowany download to GET dokładnego adresu skryptu. FormData zinterpretowało binarne pole Wasm bez filename jako tekst; binarne MIME z pobranego oryginału dało prawidłowe SHA. Zmiany dotyczyły lokalnej kontroli i odczytów, bez drugiego uploadu backendu. Pełne kroki i granice zapisano w evidence.

## Granice odbioru i następna praca

Nie przekazano Cloudflare klucza SIWA ani CloudKit, kluczy vault/HMAC lub tokenów użytkownika. Nie wykonano żądania auth do Workera/Apple, odczytu/zapisu rekordów, instalacji telefonu, aktywacji usług, zmian CloudKit Production lub płatnego planu. Brak wywołań Durable Object nie dowodzi działania SQL/alarms ani pojemności Free. Etykieta Production w panelu Cloudflare oznacza tamtejszy slot wdrożenia; ten target i CloudKit mają konfigurację Development i pozostają wyłączone.

Następny krok to przygotowana i ograniczona próba logowania właściciela z konkretnym przekazaniem sekretów, wygasaniem i sprzątaniem. Jej zakres ma obejmować profil/telefon oraz code exchange, renew/refresh i odwołanie Apple; sam logout gateway nie oznacza revoke Apple. Klucz CloudKit nie jest potrzebny w pierwszej próbie auth-only. Zwykłe A/B, query/ASSET, retencja/usuwanie i pełny adapter nadal wymagają [odbioru](ODBIOR_MIGRACJI_STAN_I_KOLEJNOSC.md). Zwykła aplikacja nadal używa dotychczasowego adaptera.

Źródła interfejsu użyte przy kontroli: [Upload Worker](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/update/), [pobranie skryptu](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/methods/get/), [metadane konkretnej wersji](https://developers.cloudflare.com/api/resources/workers/subresources/scripts/subresources/versions/methods/get/). Dowodem wykonania są odpowiedzi konta, porównane pliki i zrzuty; dokumentacja opisuje jedynie kontrakt.
