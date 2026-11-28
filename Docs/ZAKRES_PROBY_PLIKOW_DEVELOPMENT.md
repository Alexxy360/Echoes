# R-03b — zakres próby dwóch syntetycznych JPEG

**Przygotowany, niezatwierdzony i niewykonany.** Narzędzie: `gateway/scripts/avatar-asset-trial.mjs`. [Lokalne dowody](evidence/avatar-asset-trial-preparation.json). Poprzednia zgoda obejmowała wyłącznie granty i jest już wykorzystana; nie obejmuje tego uploadu.

Inwentarz SHA-256: **e0e8274935a04cbba23c0427da515e00b383de7a1daa3b752c9337bd48b52433**. Prywatnie zachowano dokładne losowe identyfikatory dwóch rekordów, początkowy checkpoint, manifesty, SQLite i lokalny klucz szyfrowania krótkotrwałych receiptów. Brak permitu, attempt i rozpoczętego okna.

Wyłącznie publiczne **CloudKit Development**, `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`, schemat SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`. Istniejący lokalny klucz „Echoes Community Development 2026-11-19”, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, SPKI SHA `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`. Nadal ma przyjęte prawa administratora publicznej bazy Development, także poza 3 km. PEM pozostaje lokalnie; Apple otrzymuje standardowy podpis S2S. Bez nowego zarejestrowanego klucza, roli, schematu lub przekazywania PEM do hostingu.

## Jeden przebieg i limity

Jedno wspólne okno do **30 minut**, maksymalnie **64 żądania API Apple łącznie z grantami, CAS i sprzątaniem**, do **2 uploadów** i **2 pobrań**. Każda operacja do 8 s, odpowiedź JSON do 16 KiB i 64 fragmentów. Budżet uploadu do 16 KiB; faktyczne dwa obrazy mają łącznie **2753 B**:

| Wariant | Wymiary | Bajty | SHA-256 |
| --- | --- | --- | --- |
| image | 192 × 96 | 1649 | 9c67d12f5d955b4357d7d2a707ce55f421c9c1b7230e0f05aaa77d2389f7be27 |
| thumbnail | 128 × 64 | 1104 | 6462e7049dff4d3381508ccc27a8e5c34444cfa9a2c78b8c93683bcc0d9ba65d |

To generowany lokalnie gradient, bez zdjęcia osoby, EXIF, GPS lub danych użytkownika. Istniejący normalizator Wasm odtwarza oba obrazy i musi ponownie uzyskać te same manifesty przed uruchomieniem.

1. Odczyt wyłącznie dwóch dokładnych losowych ID i wymaganie NOT_FOUND dla obu. Przy kolizji zatrzymanie bez zmian.
2. Utworzenie własnego `EchoesRegistryCheckpointV1` pod nazwą `community-registry-checkpoint-trial-v1-<losowy UUID>`. **Bez odczytu lub zmiany globalnego `community-registry-checkpoint-v1`.** Używany jest rzeczywisty produkcyjny rejestr/checkpoint/CAS z lokalnym trwałym SQLite.
3. Istniejące `CloudKitAvatarAssets` i `CloudKitAvatarRepository` uzyskują po jednym grancie dla `image` i `thumbnail`, przesyłają dokładne bajty i tworzą jeden własny `EchoesAvatarV1` w stanie pending. Brak publikacji profilu. Zapis jest potwierdzany dokładnym lookup i manifestami/commitmentami.
4. Osobne sprawdzenie odrzucenia starego tagu CAS na własnym checkpointcie; bez force operacji.
5. Próba pobrania obu wariantów przez istniejący bounded helper chronionego downloadu i porównanie długości oraz SHA. Nie wysyła się podpisu S2S, bearer ani cookies do hosta pliku. To sprawdza transport pliku, **nie pełny CloudKitAvatarReader, SIWA lub reguły odczytu dwóch użytkowników**.
6. Po sukcesie lub błędzie uploadu/odczytu, dopiero po odpływie konkretnego IO: świeży lookup własnych create-intentów, kontrola identyfikacji/pól/manifestu, warunkowe delete z aktualnym tagiem i potwierdzenie NOT_FOUND. Konflikt lub niepewność pozostają jawne; nie wykonuje się force delete ani kolejnego uploadu. Niepewny upload bez przypięcia może pozostać po stronie Apple.

## Dokładni odbiorcy i zatrzymanie

API wyłącznie `api.apple-cloudkit.com` i stały endpoint Development/public; dozwolone są tylko `assets/upload`, `records/lookup`, `records/modify`, dwa wskazane ID i create/replace/delete opisane powyżej. Brak query lub odczytu innych rekordów.

Upload wyłącznie **cws.icloud-content.com**, zaobserwowany w [zakończonej próbie grantów](WYNIK_ROZPOZNANIA_HOSTOW_DEVELOPMENT.md). Pobranie wyłącznie URL z dokładnie własnego rekordu, na jednym z dwóch z góry ustalonych kandydatów: **cws.icloud-content.com** albo **cvws.icloud-content.com**. Host pobierania nie jest jeszcze potwierdzony rzeczywistym odczytem; ta lista dotyczy tylko próby i nie aktywuje Runtime. Inny host lub przekierowanie oznacza odmowę, bez automatycznego poszerzania listy. Udokumentowany przez Apple końcowy segment `${f}` jest zastępowany stałym `avatar.jpg`; podpisana część query pozostaje identyczna.

Przed siecią zapis jednorazowego attempt, a przed każdym requestem trwały intent z bezpiecznym rodzajem operacji i ID własnych mutacji. Bez rawURL, receiptów, body, podpisów lub kluczy w raportach. Receipty przechowywane są zaszyfrowane w prywatnym SQLite, techniczny klucz pozostaje lokalnie poza Git. Cofnięcie/zmiana permitu, cofnięcie zegara i wygaśnięcie odcinają dalsze żądania. Restart nie uruchamia przebiegu ponownie. Przy awarii procesu lub wygaśnięciu pozostaje dokładny inwentarz i niepewny stan; wznowienie sprzątania wymaga osobnego przygotowanego zakresu, nie resetu attempt lub okna. Zakończenie procesu nie dowodzi zatrzymania pracy po stronie Apple.

**Bez prawdziwych danych/profili, prywatnej bazy, telefonu, GPS/Muzyki, logowania, Cloudflare/hostingu/transferu sekretów, Firebase, Production, TestFlight lub opłat.** Usunięcie i nieobecność rekordu nie dowodzą fizycznego wymazania assetu z Apple/CDN albo unieważnienia już istniejącego adresu.

Źródła: [oddzielne kroki grant/upload/przypięcie](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html), [asset i recordChangeTag](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html), [udokumentowany placeholder nazwy pliku](https://developer.apple.com/documentation/cloudkitjs/cloudkit.database/saverecords). Nie wywodzimy z dokumentacji gwarantowanej nazwy hosta pobierania.

## Użycie lokalne

Prepare i inspect nie korzystają z sieci ani klucza CloudKit. Run jest domyślnie wyłączony; po osobnej zgodzie wymaga `ECHOES_ALLOW_ASSET_TRIAL_DEV=1`, dokładnego SHA, prywatnego permitu i istniejącego PEM o właściwym SPKI. CLI nie udostępnia zmiany key registration lub targetu; testy programistyczne wstrzykują model dostawcy i syntetyczny klucz.

```sh
node gateway/scripts/avatar-asset-trial.mjs prepare /absolute/private/parent
node gateway/scripts/avatar-asset-trial.mjs inspect /absolute/private/run PLAN_SHA256
```

Dopiero po zgodzie:

```sh
ECHOES_ALLOW_ASSET_TRIAL_DEV=1 node gateway/scripts/avatar-asset-trial.mjs run /absolute/private/run PLAN_SHA256 /absolute/private/permit.json /absolute/private/key.pem
```

Permit: schemaVersion1, purpose `echoes-avatar-assets-development-v1`, pełny scope/SHA, window `{id,issuedAt,expiresAt}`, istniejący keyID/SPKI i identityModel `individual-owner-administrator-v1`. Sam plik permit nie jest dowodem uzyskania zgody. Przed uruchomieniem operator porówna HEAD i wszystkie źródła/skrypty ze zweryfikowaną wersją.
