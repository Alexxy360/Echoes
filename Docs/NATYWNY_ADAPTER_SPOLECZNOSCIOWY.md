# Adapter iOS, konto i trwałe żądania

CK-04d.2, 15 listopada 2026. `GatewayCommunityClient` implementuje cały istniejący `CommunityClient`; `GatewayCommunityDomain` łączy go z `CommunitySession`. Dodano chroniony dziennik, wznowienie nieznanej wiadomości, barierę konta i integrację czyszczenia z kontrolowanym hostem usuwania. Zwykły punkt wejścia AppServices nadal korzysta z Firebase. CK-04d.3 podłącza już kontrolowany host mapy/czatu i recovery UI: [opis kompozycji](KONTROLOWANY_WIDOK_SPOLECZNOSCIOWY.md). Nowe usługi i bundled aktywacja pozostają wyłączone. Nie jest to zakończona migracja ani odbiór rzeczywistych providerów.

## Dostęp i granica konta

Adapter pobiera access token przez `GatewayCommunityAuthorizationSource`. Rzeczywisty `GatewaySignInHost` sprawdza natywny stan Apple przy każdej takiej operacji oraz aktualną rewizję iCloud/sesji. Publiczne żądanie weryfikuje potem token na serwerze. Nie resetuje się całego widoku co minutę tylko z powodu okresowej kontroli logowania. Odrzucenie sesji przez serwer zamyka wyłącznie odpowiadający mu kontekst; późne odrzucenie starej sesji nie wyloguje nowej.

Przed i po każdym await sprawdzane są natywna tożsamość, jej UUID rewizji, origin i trwała lokalna lease. Rozdziela to także wylogowanie i ponowne zalogowanie na to samo konto. Każde nowe połączenie wymienia lease w Keychain; starszy obiekt klienta nie nadpisze jej po spóźnionej odpowiedzi. ID potwierdzonego zapisu jest dodatkowo wyliczane lokalnie z aktualnego właściciela/kind/logicalID i porównywane z odpowiedzią. Wiadomość musi mieć własnego autora i oryginalną treść/czas.

`GatewayCommunityDomain.invalidate()` synchronicznie zamyka klienta i czyści UI. Kontrolowany GatewayDevelopmentRuntime podpina już tę metodę przez GatewayCommunityHost do `clearDomainState` natywnego logowania. Każda prezentacja otrzymuje osobny Domain/Core, a invalidator czyści też GPS, muzykę i efemeryczne preferencje AppServices. Core ma własną epokę połączenia i okolicy, więc stary connect/send/read/stop/report/block/delete nie zmieni nowego konta ani jego flag. Po powrocie z tła nie przyjmuje się starego odczytu. Usuwanie nie zostanie wysłane przeciw nowemu kontu, gdy zmieniło się ono podczas oczekiwania na stop.

## Dziennik i nieznany wynik

Keychain ma osobny service i slot wyliczany z origin, kontenera/środowiska Development, hasha Apple/iCloud binding oraz UUID konta. Nie zapisuje się tokenu w dzienniku. Zawiera on oryginalną operację, w tym tekst/nazwę i dokładną pozycję potrzebną do ponowienia. Flagi: WhenUnlockedThisDeviceOnly, synchronizable=false, Data Protection Keychain. To prywatny, lokalny zapis, nie publiczny CloudKit i nie UserDefaults.

Odczyt/check/zastąpienie odbywają się synchronicznie na MainActor. Kontrakt dotyczy jednego procesu aplikacji; nie jest wspólnym dziennikiem rozszerzeń/wielu procesów. Maksymalnie 8 niedokończonych slotów i 32 KiB. Uszkodzenie/lock/brak miejsca zatrzymują dispatch zamiast resetować dziennik do pustego albo usuwać starsze nierozstrzygnięte wpisy. Zapis poprzedza sieć; brak potwierdzenia lub błąd lokalnego usunięcia po ack zachowuje możliwość ponowienia pod tym samym ID.

Wiadomość ma jeden nierozstrzygnięty slot. Po restarcie Core odtwarza oryginalny szkic, nazwę, pozycję i ID; nie wysyła automatycznie. Zmieniony nowy szkic nie otrzymuje drugiego ID, dopóki poprzednia próba pozostaje nierozstrzygnięta. API Core oferuje jawne ponowienie poprzedniej próby z zachowaniem nowego szkicu oraz usunięcie wyłącznie lokalnego wpisu po sprawdzeniu wyświetlonego snapshotu. Snapshot jest związany ze scope i lease, więc stary alert nie usunie nowej próby. **Lokalne usunięcie nie cofa wysłania i nie dowodzi, że wiadomość nie dotarła.** Kontrolowany czat ma teraz przyciski ponowienia i local forget oraz osobny alert z ostrzeżeniem i Anuluj. Zwykłe wysyłanie jest zablokowane, dopóki poprzednia próba pozostaje nierozstrzygnięta.

Potwierdzenie używa oryginalnego timestamp/expiresAt z serwera, także po wygaśnięciu. Nie dodaje się go do nowej okolicy, jeżeli w trakcie wysyłania zmienił się obszar lub ponawiana pozycja należy do dawnego obszaru. Zwykłe odczyty pozostają ostateczną podstawą widocznej osi czasu. Wygasły cursor resetuje stan paginacji, aby kolejny pierwszy odczyt mógł przyjąć nowy cursor.

Publish/stop mają osobny lokalny epoch; stop odcina spóźniony wynik publish i ponawia swoje zachowane ID. Pierwsze połączenie Core najpierw próbuje ukryć wcześniejszą obecność, a potem pobiera konfigurację/blokady. Po zamknięciu natywnego dostępu stary task nie uzyskuje kolejnego tokenu. Jeśli stop nie dotrze, zdalna obecność może być widoczna do serwerowego wygaśnięcia 10 min; nie obiecuje się natychmiastowego wyłączenia bez połączenia.

Zgłoszenie wymaga aktualnej używalnej pozycji Core. Jego własny UUID v8 powstaje deterministycznie z zakresu, ID wiadomości i znormalizowanej przyczyny; ponowne takie samo zgłoszenie nie zmienia ID po restarcie lub innym zgłoszeniu. Jest to ID operacji, nie credential. Nie włączono automatycznego retry ani prawdziwego procesu moderacji.

## Blokady z rewizją

Dodano POST `/v1/community/block/state` z accountID celu. Zwraca wyłącznie własne generation/blocked, także dla nieistniejącego UUID — nie ujawnia istnienia obcego konta. `block` wymaga teraz generation i potwierdza nową generation/blocked. To preaktywacyjna zmiana kontraktu Development; nie ma wdrożonych klientów tej usługi.

Rewizja jest oddzielna dla każdej własnej relacji. Nowy zamiar musi pasować do aktualnej rewizji, a identyczne ponowienie nie zwiększa jej drugi raz. Spóźniona pierwsza kopia lub powtórzenie starego, wcześniej potwierdzonego żądania nie odwróci nowszej blokady/odblokowania. Polityka nadal działa przed potwierdzeniem CloudKit i w obu kierunkach. Konflikt nie staje się pozornym sukcesem; kolejna jawna czynność odczytuje aktualny stan. Nie ma force/CAS bypass.

## Usuwanie i odbiór

`deleteOwnData` adaptera wymaga istniejącego przepływu świeżego Apple proof i sam nie wysyła legacy delete RPC. Kontrolowany `GatewayDevelopmentRuntime` usuwa teraz także właściwy slot journala w swoim `clearLocalData`. Scope powstaje z oryginalnego privateScope i binding zadania; nie bierze właściciela z aktualnie widocznego konta. Błąd Keychain uniemożliwia lokalny checkpoint/ACK, a powtórne czyszczenie jest idempotentne. Cudzy/nowszy scope pozostaje nienaruszony.

190/190 testów EchoesCloudKit (19 nowych) oraz 22/22 Core (9 nowych). Obejmują restart/utracony ack, storage przed i po sieci, lease/ABA, natywne credentials, podmianę autora, publish/stop, per-target block CAS, zgłoszenia, scoped erase, limity, recovery/forget szkicu, cursor, stary obszar i usuwanie podczas zmiany konta. Gateway 257/257 na Node 22/24 (1 nowy test CAS, istniejące testy i 14 par JS/Swift dostosowane). Osobna kopia bez pojedynczego porównania generation rzeczywiście akceptuje stary blok i oblewa test; źródła właściwe niezmienione.

Signed ad-hoc iPhone 17 Pro Simulator/iOS 26.1: kontrola prawdziwego Keychain odtworzyła nierozstrzygniętą operację przez nowy klient/lease, zweryfikowała ochronę i limit, rozdzieliła dwa losowe zakresy, usunęła A bez naruszenia B, a następnie posprzątała oba. Natywna tożsamość i HTTP w tej kontroli są jawnie syntetyczne; nie użyto konta/GPS/sieci. [Obejrzany wynik](evidence/community-journal-keychain.png) to `passed`; pierwszy plik przekierowanego stdout nie był dostępny w oczekiwanej ścieżce. Końcowy przebieg na finalnym Debug przechwycono przez console-pty: community/storage/deletion result=passed, oba session/deletion sloty po cleanup NOT_FOUND. Nie testowano fizycznego lock/reboot/backup/restore telefonu.

Regresja 10/10 XCTest UI obejmuje dotychczasowe demo i kontrolowany przepływ usuwania. Nie jest to wizualny odbiór przyszłego natywnego ekranu mapy/czatu. Wyniki kompilacji, kontrole pakietu i SHA: [community-client-local-tests.json](evidence/community-client-local-tests.json).

Kontrolowany host/AppServices i recovery UI podłączono w CK-04d.3; [oddzielne wyniki](evidence/community-host-local-tests.json). Pozostają: profile/zdjęcia, fizyczna retencja, operator/kontakt, realne SIWA/schemat/role/Workers Free i dwa zwykłe konta A/B, a potem odłączenie Firebase i przygotowanie wydania. Brak nowych usług, uprawnień, sekretów, opłat, danych użytkowników oraz publikacji Production/TestFlight.
