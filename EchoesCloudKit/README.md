# EchoesCloudKit

Niezależna warstwa przygotowywanej migracji. Nie jest jeszcze adapterem CommunityClient i nie jest podłączona do głównej aplikacji. Nie publikuje danych i nie zmienia konfiguracji Apple.

- `CloudKitConfiguration`: jawny identyfikator kontenera i środowisko; walidacja uprawnień dostarczonych przez narzędzia podpisywania. Nie generuje kontenera i nie nadaje uprawnień.
- `NativeCloudKitAccountSource`: natywne accountStatus/userRecordID. Tworzyć wyłącznie w uprawnionym, podpisanym hoście po konfiguracji kontenera.
- `CloudKitAccountSession`: czyści tożsamość przed sprawdzeniem konta; revision umożliwia unieważnienie cache w przyszłym adapterze. Spóźnione wyniki nie przywracają poprzedniego konta. Host zarządza startMonitoring/stopMonitoring i czyści własne cache przy zmianie revision.
- `CloudKitFailure`: bezpieczne komunikaty, konflikty, częściowy sukces i wskazówki retryAfter. Nie ponawia automatycznie zapisów, które mogły już się wykonać.

Testy offline: `swift test --package-path EchoesCloudKit`. Źródło natywne nie jest wywoływane przez testy stubów. Nie zastępują one testów dwóch rzeczywistych kont w CloudKit Development.
