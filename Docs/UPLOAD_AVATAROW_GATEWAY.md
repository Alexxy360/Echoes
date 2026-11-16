# Kontrolowany transport uploadu zdjęć

Etap CK-04e.3b implementuje trwałą rezerwację i pierwsze dwa kroki uploadu CloudKit: pozyskanie adresu oraz wysłanie bajtów. Nie jest jeszcze kompletną funkcją zdjęć. Moduł nie jest importowany przez runtime ani dostępny przez HTTP; nie utworzono typu/ról/usługi/sekretów w chmurze. Wszystkie dotychczasowe flagi wdrożenia pozostają `0`.

## Rezerwacja przed siecią

`avatar` jest szóstym rodzajem rekordów rejestru; nazwa `community-v1-avatar-<digest>` wynika z UUID konta i niemodyfikowalnej wersji zdjęcia. Proponowany typ to `EchoesAvatarV1`, pola assetów `image` i `thumbnail`. Definicja schematu wymaga późniejszej konkretnej konfiguracji Development; dodanie nazwy w kodzie nie tworzy typu w Apple.

PublicRecordRegistry dopuszcza dla avatarów tylko create, bez CAS zastępującego plik tej samej wersji. W tej samej prywatnej bazie SQLite powstaje `avatar_asset_transfers_v1`: najwyżej jeden wiersz na wersję i wariant. Zawiera ID próby, powiązanie request/generation/payload, skrót i rozmiar bajtów, fazę oraz skrót receipt; bez zdjęć, URL, receipts lub wrapping keys. Obowiązują istniejące limity wszystkich rezerwacji: 1000 na konto, 10000 w kontrolowanym środowisku, najwyżej dwa transfery na rezerwację avatara. To limity pojemności Development, nie pełna polityka upload rate lub retencji.

Claim zapisuje się i synchronizuje **przed** żądaniem o adres uploadu. Zdalny checkpoint musi zostać przesunięty przed siecią assetów; cofnięcie całej bazy SQLite za ten punkt blokuje próbę. Ponowienie po nieznanym wyniku albo po restarcie jest odrzucane, również gdy grant/receipt nie dotarł. Nie można bezpiecznie potraktować nieznanego wyniku jako braku pliku. Brak całej tabeli transferów przy istniejących rezerwacjach avatarów zatrzymuje otwarcie zamiast resetować próby. Ochrona punktu kontrolnego dotyczy spójnego cofnięcia SQLite; nie dowodzi wykrycia każdej ręcznej modyfikacji pojedynczego wiersza.

## Transport Development/public

CloudKitAvatarAssets wymaga istniejącej rezerwacji, rejestru, checkpointu, świeżego synchronicznego callbacku sesji/zgody i aktywnej konfiguracji. Bajty mają być już zweryfikowane i znormalizowane przez zaufany pipeline serwera. **Moduł nie jest walidatorem JPEG**: kontroluje tylko typ bufora, limit, kopię bajtów oraz SHA-256. Żaden manifest przesłany przez zmodyfikowanego klienta nie może zastąpić serwerowego dekodowania i moderacji.

1. Podpisane `assets/upload` trafia tylko do `api.apple-cloudkit.com`, stałego kontenera `iCloud.mpvEcho.Echo`, Development/public, dokładnie jednego recordName i jednego pola. Sygnatura obejmuje rzeczywiste body, czas i ścieżkę.
2. Odpowiedź musi zawierać jeden pasujący token. URL jest akceptowany wyłącznie dla dokładnego hosta z wcześniej zweryfikowanej listy, HTTPS, bez credentials, portu, fragmentu i niekanonicznej reprezentacji. Lista jest domyślnie pusta i konstrukcja wtedy odmawia działania. Nie skonfigurowano żadnego rzeczywistego hosta.
3. Dodatkowy filtr ogranicza listę do subdomen `icloud-content.com`, `icloud.com` lub `apple-cloudkit.com`. Apple wymienia te rodziny jako używane przez iCloud, ale **nie dowodzi to poprawności konkretnego URL uploadu**. Potrzebny jest odbiór rzeczywistej odpowiedzi i dokładnych hostów. [Sieci Apple](https://support.apple.com/en-us/101555).
4. Upload dostaje nowy Request: `credentials: omit`, wyłącznie Content-Type/Cache-Control, bez klucza, sygnatury, bearer i cookies. Oba żądania mają `redirect: manual`; 3xx kończy próbę. Snapshot bufora chroni przed zmianą bajtów podczas await.
5. JSON obu odpowiedzi ograniczony do 16 KiB i 64 niepustych fragmentów także strumieniowo; Content-Length, UTF-8, typ, zamknięte pola i rozmiar receipt są sprawdzane. Jeden wspólny deadline do 8 sekund i sygnał anulowania obejmują checkpoint oraz transport. Termin jest dodatkowo sprawdzany zegarem podczas odczytu, aby gotowe mikrofragmenty nie odsuwały obsługi timera. Przed i po całej odpowiedzi sprawdzane są świeże uprawnienia; wewnątrz pętli strumienia kontrola transportu nie odpytuje SQLite dla każdego fragmentu. Spóźniona odpowiedź nie rozpoczyna kolejnego żądania.
6. Potwierdzenie zapisuje tylko hash receipt i synchronizuje SQLite oraz checkpoint. Dopiero potem zwraca niejawny uchwyt, bez sekretów we własnościach i JSON. Zaufany builder może uzyskać pole ASSET przez maksymalnie dwie minuty, wyłącznie dla tej samej wersji/wariantu/request/generation, po ponownej autoryzacji. Uchwyt nie działa w drugim kliencie. Receipts nie trafiają do publicznego DTO.

[Protokół Apple uploadu](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html) ma także trzeci krok: zapis rekordu z uzyskanym assetem. Ten etap go **nie wykonuje** i nie oznacza przyjęcia uploadu jako publikacji. [Pola słownika assetu](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/Types.html) rozróżniają receipt zapisu od downloadURL odczytu.

## Usuwanie i nieznane wyniki

Istniejący eraser obejmuje nowy rodzaj rekordów dokładnie według rejestru. Tworzy fence również dla zarezerwowanego, lecz nieutworzonego rekordu. Odczyt metadanych i warunkowe replace usuwają pola assetów bez odzyskiwania treści lub wyliczania cudzych danych. W tej samej transakcji co oznaczenie erasure w rejestrze czyszczone są skróty/rozmiary/czasy/ID transferu; pozostaje minimalny marker recordName/wariant/erased. Błąd SQL nie daje fałszywego ACK. Spóźnione potwierdzenie lub zapis z poprzedniej generacji nie przywraca danych.

Nieprzypisany plik wysłany przed błędem lub usuwaniem może nadal istnieć w magazynie Apple. Ten kod nie ma API do jego fizycznego usunięcia ani dowodu terminu garbage collection. Po usunięciu pola/rekordu także nie gwarantuje natychmiastowego odzyskania miejsca. Rezerwacja zostaje zużyta; kolejna wersja wymaga osobnej, ograniczonej decyzji uploadu. Fizyczną retencję i koszt trzeba odebrać przed aktywacją.

## Weryfikacja i pozostała integracja

Testy korzystają z rzeczywistego lokalnego SQLite/crypto/checkpointu i jawnego modelu transportu Apple. Obejmują sygnaturę i brak nagłówków na hoście assetów, trwałość przed dispatch, współbieżność i reopen, nieznany wynik, SQL/sync, metadane i erasure, cofnięcie SQLite, limity, błędne hosty/URL/receipts, 3xx, deadline i anulowanie czytanego body. Dane binarne są syntetycznym modelem protokołu, nie dowodem walidacji JPEG ani prawdziwego CloudKit. [Raport i SHA](evidence/avatar-assets-local-tests.json).

Kolejność dalszej pracy: serwerowa normalizacja/dekodowanie i pomiar CPU/pamięci Workers Free; trwałe odzyskiwanie/powiązanie receipt i warunkowe utworzenie niezmiennego rekordu; zgoda/moderacja i CAS wskazania w profilu; świeżo autoryzowany odczyt bez surowych URLs oraz cache/odcięcie późnych wyników w iOS; retencja i odbiór Development/ról/dwóch zwykłych kont. Nie wolno aktywować modułu przez samo wypełnienie listy hostów. [Pełny plan zdjęć](PLAN_AVATAROW_CLOUDKIT.md), [natywny odbiór bajtów](AVATAR_ODBIOR_PLIKOW_IOS.md), [plan migracji](PLAN_MIGRACJI_CLOUDKIT.md).


## Aktualizacja CK-04e.3d

Powyższy CK-04e.3b opisuje pierwszy etap transportu. Obecny kod wymaga AvatarReceiptVault: ACK zawiera dodatkowo hash provider fileChecksum i zaszyfrowaną kopertę receipt z terminem użycia. Rejestr ustawia claim mask w tej samej transakcji co rezerwacja wariantu; brak metadanych nie zwalnia próby. Osobne resumedRecordField odtwarza tylko istniejący, aktualny receipt po ponownym sprawdzeniu konta/operacji. Nowy repository wykonuje trzeci krok create-only, dokładny lookup i settled/cleanup; dalej nie publikuje zdjęcia w profilu. Utrata odpowiedzi samego uploadu pozostaje nieznana i nie uruchamia reuploadu. [Aktualny kontrakt i otwarte integracje](REKORD_AVATARA_I_ODZYSKIWANIE.md).
