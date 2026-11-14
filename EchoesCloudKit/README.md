# EchoesCloudKit

Niezależna warstwa przygotowywanej migracji. Jest lokalną zależnością głównej aplikacji i działa w ograniczonym trybie diagnostycznym Debug; nie jest jeszcze adapterem CommunityClient. Sam pakiet nie rejestruje usług Apple ani nie publikuje danych społecznościowych. Podpisany host przeszedł syntetyczny test prywatnej bazy Development jednego konta; [zakres i wyniki](../Docs/CLOUDKIT_WERYFIKACJA.md).

- `CloudKitConfiguration`: jawny identyfikator kontenera i środowisko; walidacja uprawnień dostarczonych przez narzędzia podpisywania. Nie generuje kontenera i nie nadaje uprawnień.
- `NativeCloudKitAccountSource`: natywne accountStatus/userRecordID. Tworzyć wyłącznie w uprawnionym, podpisanym hoście po konfiguracji kontenera.
- `CloudKitAccountSession`: czyści tożsamość przed sprawdzeniem konta; revision umożliwia unieważnienie cache w przyszłym adapterze. Spóźnione wyniki nie przywracają poprzedniego konta. Host zarządza startMonitoring/stopMonitoring i czyści własne cache przy zmianie revision.
- `CloudKitFailure`: bezpieczne komunikaty, konflikty, częściowy sukces i wskazówki retryAfter. Nie ponawia automatycznie zapisów, które mogły już się wykonać.

Testy offline: `swift test --package-path EchoesCloudKit`. Źródło natywne nie jest wywoływane przez testy stubów. Nie zastępują one testów dwóch rzeczywistych kont w CloudKit Development.

## Prywatny profil i przygotowanie avatara (CK-03a)

`PrivateProfileStore` zapisuje obecnie wyłącznie pseudonim w prywatnej bazie użytkownika. To przygotowana warstwa danych, jeszcze bez ekranu edycji w głównej aplikacji. Nie publikuje profilu. Po połączeniu `CloudKitAccountSession` trzeba wykonać `load()`, a następnie świadome `save(displayName:)`. Nie migrujemy nazwy z UserDefaults bez wyboru użytkownika. Obsłużono brak rekordu, konflikt wersji, nowszy schemat, częściowe błędy i zmianę konta. `delete()` usuwa wyłącznie rekord profilu, a nie konto Apple ani inne dane. Interfejs użytkownika wywołujący usuwanie musi najpierw uzyskać odpowiednie potwierdzenie.

`NativePrivateProfileDatabase` zawsze używa privateCloudDatabase. Rekord `EchoesPrivateProfileV1/private-profile.v1` ma schemaVersion=1 i displayName; zachowuje nieznane pola podczas edycji. Zapis używa ifServerRecordUnchanged, bez cichego nadpisywania i ponawiania konfliktów.

`AvatarPreparer.prepare(_:)` działa lokalnie: przyjmuje pojedyncze zdjęcie JPEG/PNG/HEIC/HEIF do 8 MB i 40 mln pikseli (maksymalny bok 12000), normalizuje orientację i tworzy JPEG o boku do 512 px oraz miniaturę do 128 px. Limit wyniku: 256 KB i 32 KB. Reenkodowanie usuwa źródłowe GPS/EXIF i dane aparatu. Przezroczystość spłaszczana jest na białe tło. Przetwarzanie wywoływać poza aktorem UI. Ten kod nie uploaduje plików ani nie tworzy jeszcze CKAsset.

Zależność od lokalnego EchoesCore zapewnia tę samą walidację pseudonimu co pozostała aplikacja. Testy są offline; potwierdzenie dostępu dwóch rzeczywistych kont pozostaje częścią odbioru.

## Natywna sesja bramki (CK-02j)

GatewayHTTPClient/NativeGatewayTransport, KeychainGatewaySessionStorage i GatewaySessionController obsługują protokół auth, single-flight i trwały stan nieznanego wyniku rotacji. AppleGatewayAuthorizationAttempt przygotowuje nonce/state i sprawdza odpowiedź. Host musi jeszcze przedstawić arkusz Apple, zweryfikować credentialState/konto CloudKit i podłączyć cykl życia oraz UI. Nie jest to adapter CommunityClient i nie ma domyślnego adresu usługi.

44/44 lokalne testy Swift oraz osobna udana kontrola Keychain w aplikacji Debug na symulatorze. Bez prawdziwego Apple login lub nowego wdrożenia. [Dokładny kontrakt, granice i dalszy odbiór](../Docs/NATYWNA_SESJA_GATEWAY.md).
