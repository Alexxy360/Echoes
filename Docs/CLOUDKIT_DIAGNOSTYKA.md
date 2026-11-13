# Diagnostyka prawdziwego CloudKit — Development

App ID `mpvEcho.Echo` i kontener `iCloud.mpvEcho.Echo` zostały zarejestrowane i powiązane w zespole `22YC9RAP4P` po bezpośredniej zgodzie właściciela. Konsola potwierdziła kontener w środowisku Dev. Nie promowano schematu do Production.

## Tryb testowy

Wyłącznie w Debug ustawić `ECHOES_CLOUDKIT_PROBE=1`. Opcjonalne `ECHOES_CLOUDKIT_PROBE_AUTORUN=1` uruchamia jeden test po otwarciu ekranu. Release ignoruje te przełączniki i nie zawiera implementacji próby.

Wariant pomija inicjalizację Firebase oraz widok mapy, GPS i muzykę. Zwykły tryb demonstracyjny i dotychczasowy klient nie są przełączone na CloudKit. Debug ma osobny plik `Echo/Echo-Debug.entitlements`: CloudKit z jawnie zweryfikowanym kontenerem i środowiskiem Development. Release zachowuje wcześniejsze entitlements do etapu odłączenia Firebase.

Próbę wolno uruchamiać w podpisanym hoście po sprawdzeniu uprawnień i profilu, nie w dowolnym nieuprawnionym programie CLI.

## Zakres jednej próby

1. Sprawdzenie rzeczywistego statusu konta iCloud i tożsamości zwracanej przez Apple.
2. Utworzenie jednego syntetycznego rekordu `EchoesAccessProbeV1` w **privateCloudDatabase**. Nazwa rekordu ma losowy prefiks `echoes-probe-` i UUID. Pola to wyłącznie losowy nonce oraz wersja schematu.
3. Odczyt tego samego rekordu i porównanie nonce oraz metadanych twórcy. Rozróżniamy zgodność z resolved userRecordID i alias `CKCurrentUserDefaultName`, oznaczający bieżącego użytkownika. Akceptacja aliasu dotyczy tylko tej próby prywatnej; nie służy autoryzacji publicznych operacji.
4. Próba usunięcia wyłącznie losowego rekordu tego przebiegu, także po błędzie odpowiedzi zapisu/odczytu, jeśli konto nie zmieniło się podczas operacji. Błąd sprzątania jest raportowany osobno; brak rekordu oznacza potwierdzoną nieobecność. Nie są usuwane profile ani żadne istniejące rekordy użytkowników.
5. Zapis raportu lokalnego do `Documents/cloudkit-probe-result.json`. Raport zawiera nowy runIdentifier i czas początku, booleany, bezpieczny komunikat/kod błędu i opcjonalną nazwę syntetycznego rekordu. Przy ponownym pobraniu weryfikujemy nowy runIdentifier/czas i nazwę rekordu, żeby nie uznać starego pliku za świeży wynik. Nie zapisuje identyfikatora użytkownika iCloud, tokenów, nazw profilu, GPS ani utworów.

Development może automatycznie utworzyć typ i pola rekordu przy pierwszym zapisie. To nie jest publikacja schematu produkcyjnego ani dowód poprawności publicznych ról. Jeśli zapis wykona się, a późniejsza operacja zawiedzie, raport nie deklaruje sprzątnięcia; pozostały rekord identyfikujemy po zapisanej nazwie i sprzątamy w uzgodnionym workflow Development.

## Co test potwierdza, a czego nie

Poprawny zapis, odczyt, metadane autora i usunięcie w prywatnej bazie jednego rzeczywistego konta. Nie zastępuje testu dwóch kont, odczytu danych prywatnych z konta B, publicznych ról, moderacji, retencji wiadomości ani odbioru gotowej migracji.

## Podpisywanie i urządzenie

Podpisany build z automatycznym provisioningiem może wygenerować nowy profil Apple. Instalacja na fizycznym iPhonie aktualizuje istniejącą deweloperską aplikację Echoes z tym samym Bundle ID. Nie odinstalowujemy aplikacji ani nie kasujemy jej kontenera danych. Właściciel osobno zatwierdził provisioning, instalację i ograniczoną próbę prywatną. Zgoda na App ID nie była traktowana jako zgoda na instalację. Test wykonano; nie wymaga ponownego potwierdzania przy odczycie jego raportu.

Przykładowy build po zgodzie na provisioning: `xcodebuild -project Echoes.xcodeproj -scheme Echoes -configuration Debug -destination 'platform=iOS,id=DEVICE_UDID' -allowProvisioningUpdates build`. Raport porównujemy z faktycznym wynikiem na urządzeniu; testów offline nie przedstawiamy jako odpowiedzi Apple.

## Potwierdzony wynik

Na zatwierdzonym iPhonie 15 Pro przeszły operacje prywatne opisane w [weryfikacji](CLOUDKIT_WERYFIKACJA.md); [raport](evidence/cloudkit-private-probe-development.json) nie zawiera danych konta. Dwa wykonane rekordy testowe zostały usunięte. Test dwóch kont i publicznych ról pozostaje niewykonany. Na urządzeniu zainstalowano Debug; ekran diagnostyczny nie trafia do Release.

Kontrola rzeczywistego podpisu (przykładowe ścieżki do lokalnego buildu):

```sh
codesign -d --entitlements :- /path/to/Echoes.app > /tmp/echoes-signed-entitlements.plist
python3 scripts/cloudkit-preflight.py --entitlements /tmp/echoes-signed-entitlements.plist --profile /path/to/Echoes.app/embedded.mobileprovision --container iCloud.mpvEcho.Echo --environment Development --strict
```

`entitlements-match` potwierdza konfigurację dostarczonych plików, a wynik próby urządzeniowej — konkretne operacje na jednym koncie. Żaden z nich sam nie potwierdza izolacji dwóch kont.

Podstawa interpretacji aliasu: [CKCurrentUserDefaultName](https://developer.apple.com/documentation/cloudkit/ckcurrentuserdefaultname) oraz zaobserwowane `creatorUsesCurrentUserAlias` w raporcie. Brak aliasu i brak zgodnego resolved ID pozostawia autora niepotwierdzonym.

## Kontrola tożsamości konta — CK-02c

Wyłącznie Debug: `ECHOES_CLOUDKIT_IDENTITY_CHECK=1`, opcjonalnie `ECHOES_CLOUDKIT_IDENTITY_AUTORUN=1`. W `ECHOES_CLOUDKIT_SERVICE_ID_HASH` operator przekazuje SHA-256 userRecordName ustalonego wcześniej z zatwierdzonego klucza. Hash jest porównywany lokalnie; raport nie zapisuje ani surowej tożsamości, ani jej hasha.

Ten osobny ekran pomija Firebase i funkcje społecznościowe. Wykonuje wyłącznie natywne sprawdzenie dostępności konta i jego identyfikatora. Nie pobiera prywatnego/publicznego profilu i nie odczytuje, nie tworzy ani nie kasuje rekordów aplikacji. Zapisuje lokalnie `Documents/cloudkit-identity-result.json`: UUID/czas, tryb i booleany oraz ewentualny bezpieczny błąd.

Wynik z iPhone’a 15 Pro: konto dostępne, zgodne z tożsamością klucza. [Raport](evidence/cloudkit-identity-check-device.json), przebieg `571651FC-BFB8-42F7-B4CC-E74350214520`, `2026-11-13T09:28:14Z`. Nie jest to próba odmowy dostępu dla innego użytkownika. Właściciel ma obecnie tylko jedno konto; A/B pozostaje warunkiem odbioru przed publikacją.

Tryb oraz ekran nie trafiają do Release. Sam wynik porównania jest diagnostyką operatora, nie mechanizmem autoryzacji backendu.
