# Natywne usuwanie konta i ekran kontrolny — CK-02o

Stan: 15 listopada 2026. Zaimplementowano host tożsamości, ekran kontrolny Debug, selektywne zamknięcie sesji oraz czyszczenie własnych plików cache. Zwykły klient nadal korzysta z Firebase. Brak aktywacji bramki oznacza niedostępność funkcji; nie jest zastępowany podglądem. Nie wdrożono usług ani pełnego usuwania konta w zwykłym interfejsie.

## Tożsamość i potwierdzenie

`GatewayDeletionHost` używa osobnej sesji konta CloudKit i osobnego delegata Apple niż host logowania. Sprawdzenie jednej funkcji nie unieważnia revision drugiej. Wskazówki z chronionego dziennika są ograniczone do aktualnego iCloud i nie stanowią autoryzacji. Surowe Apple userID i nazwa rekordu iCloud nie są wyświetlane ani logowane.

Nowe usunięcie, odzyskanie biletu i ponowne potwierdzenie nieprzyjętego pierwszego żądania wymagają świadomego potwierdzenia oraz nowego dowodu Apple właściwego purpose. Jednorazowe potwierdzenie jest przypięte do generation, native revision, iCloud, binding i aktualnego konta Echoes. Przed i po arkuszu host sprawdza tożsamość oraz zgodność Apple userID; nonce/state obsługuje natywny authorizer. Synchroniczna rezerwacja kliknięcia chroni przed anulowaniem przez automatyczne zamknięcie alertu SwiftUI przed startem Task.

Zaakceptowany ważny bilet może wznowić status/czyszczenie po odwołaniu Apple bez nowego arkusza. Otwarcie widoku nie zleca usunięcia. Sprawdzenie statusu i każda strona cleanera wymagają osobnego działania; brak pętli sieciowych/retry. Błąd dziennika nie staje się pustym kontem i blokuje nowy arkusz. Background, blokada chronionych danych i zmiana konta odcinają pracę oraz widok, zachowując dziennik. Powiadomienie odwołania Apple przerywa pracę i odświeża lokalne wskazówki; zadanie nie może wznowić zatrzymanego hosta.

## Selektywne zamknięcie dostępu

`GatewaySignInHost.prepareForAccountDeletion` i aktor sesji zamykają pasujący binding oraz znane konto Echoes. Odzyskiwanie starego receipt zachowuje nową rejestrację tej samej osoby. Przy nieznanym accountID zamknięcie następuje po autorytatywnej odpowiedzi. Błąd odczytu chronionej sesji ukrywa nieweryfikowalny dostęp.

Trwały tombstone poprzedza dalszą pracę; generation odcina stare logowanie/odnowienie. Pending renewal zapisuje accountID bez starego proof; opcjonalne pole jest zgodne ze starszym zapisem. Po odblokowaniu storage nowa próba ponownie rzeczywiście wykonuje operacje zamiast dziedziczyć błąd poprzedniej bariery. Ta ścieżka nie wykonuje zdalnego logout obcego konta.

Wspólny `GatewayDeletionJournalCodec` zachowuje walidację CK-02n. Ponowne potwierdzenie nieprzyjętego initial request zachowuje bilet/UUID, wymaga nowego dowodu i nie tworzy drugiego zadania. Nie dotyczy zadania już zaakceptowanego.

## Pliki lokalne

`GatewayLocalAccountData` jest aktorem odtwarzalnego cache w zaufanym katalogu sandboxa. Posiada wyłącznie `EchoesCloudKitData/<scope.digest>/` i trzy nazwy: `profile.json` do 32 KiB, `avatar.jpg` do 256 KiB, `thumbnail.jpg` do 32 KiB. Nowy rodzaj cache wymaga jawnego rozszerzenia; nieznany plik blokuje pełne sprzątnięcie.

Lease wiąże zapis/odczyt z binding i przestrzenią konta. Zmiana lease/fence/usuwanie odcina późne zapisy, zachowując inne konto. Stałe nazwy, `openat`/`unlinkat` i `O_NOFOLLOW` nie śledzą dowiązań; odczyt/zapis odrzuca hardlinki, nieregularne pliki i przekroczenia rozmiaru. Metadane są sprawdzane przed truncate, a iOS `FileProtection.complete` jest ustawiana przed treścią. Czyszczenie dotyczy dokładnego scope, jest idempotentne i nie zamienia błędu w ACK. To nie jest granica kryptograficzna przeciw zmodyfikowanemu klientowi lub właścicielowi urządzenia.

`GatewayDevelopmentRuntime` łączy cleaner i zamknięcie sesji ze sterownikiem. `NativePrivateProfileDatabase` służy tu wyłącznie usuwaniu. Izolowany ekran nie posiada pamięci profilu, dlatego `clearDomainState` jest jawnie pusty. Integracja zwykłego AppServices/profilu musi podłączyć wszystkie pamięci oraz lease. Stary Firebase i jego cache nie są czyszczone.

## Interfejs i podgląd

Widok rozróżnia dane społecznościowe, prywatną zawartość, dane bieżącego urządzenia, globalny stan pozostałych urządzeń i ręczne odłączenie Apple. „Zakończone na tym urządzeniu” wymaga własnych checkpointów. Potwierdzenie ma osobne „Anuluj”; treść przewija się przy Accessibility XXXL. Okno arkusza pochodzi ze stabilnego czytnika UIView sceny, bez dowolnego fallback UIWindow.

`ECHOES_GATEWAY_DELETION_UI_PREVIEW=pending|completed|recovery` istnieje wyłącznie w Debug i wymaga jawnego wyboru. Używa modeli w pamięci z bannerem danych syntetycznych, bez HTTP, CKContainer, prawdziwego Apple, Keychain lub plików użytkownika. Authorizer odrzuca potwierdzenie błędem konfiguracji, zamiast udawać dowód. Brak konfiguracji natywnej nie przechodzi w podgląd. Release nie zawiera kontrolnego UI.

## Weryfikacja i pozostały odbiór

- 151/151 Swift na macOS, w tym 26 nowych: 15 hosta usuwania, 5 rzeczywistego lokalnego systemu plików i 6 selektywnego zamknięcia sesji/hosta. API, Apple i transport stref są modelami.
- 9/9 XCTest UI na iPhone 17 Pro/iOS Simulator 26.1: 4 dotychczasowe demo i 5 nowych. Pending → własne kroki, anulowanie/wykonanie alertu, brak fałszywego sukcesu, duży tekst i unconfigured. Zrzuty przejrzano wizualnie; [raport i hashe](evidence/deletion-host-local-tests.json).
- Debug podpisany lokalnie ad-hoc i Release bez podpisywania skompilowane z projektem z Git, bez provisioning updates. Później zmieniono wyłącznie format komentarzy w dwóch plikach; strict lint wszystkich 20 plików przeszedł. Testów po zmianie komentarzy nie powtarzano. Release nie zawiera markerów trybu kontrolnego ani aktywacji.
- Wcześniejsze przebiegi UI wykryły nakładanie bannera na tytuł, pomijany start scene i wyścig zamknięcia alertu. Poprawiono produkt i dodano test kliknięcia. Inne nieudane asercje dotyczyły Cancel/AX oraz `isHittable` dla tekstu: czytelność sprawdza teraz przecięcie z obszarem widoku; przyciski nadal wymagają hittable. Nie ograniczono Dynamic Type w celu zaliczenia testów.

Nie ponawiano rzeczywistej kontroli Keychain CK-02n. Nie zaliczono Apple login/revoke, SDK CloudKit/CKAsset, Cloudflare runtime ani A/B zwykłych kont. Nadal wymagane: adapter społecznościowy/serwerowego usuwania, profile/zdjęcia i cały cache, retencja receipts/guarda, legacy, SIWA i rzeczywiste próby. Brak zmian uprawnień, sekretów, usług, opłat, Production i dawnych danych Firebase. Nie jest to ukończona migracja lub gotowość TestFlight.
