# Usuwanie konta i odwołanie dostępu — CK-02h

Stan: 14 listopada 2026. Lokalny sterownik procesu i testy SQLite; bez endpointu, alarmu, wdrożenia i prawdziwych danych użytkowników. Zwykła aplikacja nadal używa Firebase. **Nie zaimplementowano jeszcze rzeczywistego adaptera kasowania publicznych rekordów CloudKit ani natywnej ścieżki usunięcia prywatnej bazy.** Ich brak nie daje domyślnego sukcesu.

## Własność i autoryzacja żądania

Usunięcie wymaga świeżego ID tokenu Apple z podpisem/czasem/issuer/native audience i nonce z jednorazowego wyzwania przeznaczonego wyłącznie dla `account_deletion`. Wyzwanie logowania nie działa w tym przepływie i odwrotnie. Serwer wybiera właściciela ze zweryfikowanego sub; optional expectedAccountID służy wyłącznie wykryciu zmiany konta w UI. Nie pozwala wybrać innej osoby do skasowania. Termin tożsamości jest ponownie sprawdzany przed zapisem.

Ten przepływ nie wymienia nowego authorization code i nie tworzy kolejnego refresh tokenu. Podpisany, świeży dowód z nonce uwierzytelnia żądanie erasure; znane tokeny są już w magazynie. Usunięcie danych musi być możliwe również przy braku refresh lub zapełnionym magazynie. Jest dostępne także właścicielowi konta zablokowanego przez operatora. To osobna operacja właściciela, bez przyznania mu normalnej sesji. [Apple: weryfikacja tożsamości](https://developer.apple.com/documentation/signinwithapple/verifying-a-user), [TN3194: usunięcie danych przy braku tokenu](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

Jedna transakcja zapisuje zadanie, blokuje konto, zwiększa generację wszystkich sesji i zapisuje znacznik czasu odcinający starsze wyzwania. Potwierdzenie trwałości poprzedza odpowiedź. Nowe publikacje/sesje są zablokowane. Stare logowanie nie może odtworzyć konta po zakończeniu zadania. Późny znany refresh z operacji już w toku może zostać zachowany do odwołania, bez wydania sesji; aktywne rezerwacje opóźniają końcowe sprzątanie.

Klient przygotowuje losowy deletionID i 256-bitowy statusToken, **zapisuje je przed żądaniem**, a potem używa do odczytu statusu i potwierdzenia prywatnego sprzątania. Baza ma wyłącznie skrót tokenu. Powtórzenie z tym samym dowodem odzyskuje istniejący wynik bez kolejnej autoryzacji i bez powielania zadania, także gdy pierwsza odpowiedź zginęła po zapisie. Ten wąski sekret nie pozwala utworzyć innego zadania, czytać profilu, uruchamiać operatora lub wybrać właściciela. Bilet ma być przesyłany w nagłówku lub body przez TLS, bez umieszczania sekretu w URL/logach. Natywny Keychain/odzyskiwanie nie są jeszcze podłączone.

## Trzy niezależne części

| Część | Potwierdzenie | Granica obecnego kodu |
| --- | --- | --- |
| Publiczne dane aplikacji | Receipt z zaufanego adaptera: zgodne accountID/deletionID i informacja, czy pozostały rekordy | Adapter jest obowiązkową zależnością; testy używają jawnego zbioru w pamięci. Nie wykonano kasowania w CloudKit. |
| Prywatne dane iCloud | Potwierdzenie urządzenia posiadającego wąski bilet zadania | Serwer nie ma dostępu do prywatnej bazy. Status mówi device-acknowledged, a nie „zweryfikowane przez serwer”. |
| Tokeny Apple i lokalna tożsamość | Odpowiedź revoke dla zachowanych tokenów, rozstrzygnięcie rezerwacji i trwałe usunięcie lokalnych rekordów auth | Brak tokenu/błąd kończy się manual-required; nigdy deklaracją unieważnienia wszystkich historycznych autoryzacji Apple. |

AccountDeletionProcessor wykonuje najwyżej jedną partię publiczną i jedno odwołanie na krok. Adapter dostaje wyłącznie zaufane UUID właściciela/zadania, limit 100 i AbortSignal; timeout wynosi do 10 s. Ma ponownie pytać o pierwszą partię pozostałych własnych rekordów, a nie zakładać, że klient skasował dane. Receipt innego właściciela, brak remaining lub błąd nie oznaczają sukcesu.

Pierwszy pusty skan przed upływem 60 s oznacza draining. Po tym okresie następuje ponowny skan przed oznaczeniem danych jako usunięte. **To nie zastępuje rejestru nieznanych wyników zapisów społecznościowych**: przyszły adapter ma sprawdzić wszystkie objęte typy oraz powiązane operacje w toku. Sam filtr właściciela w UI ani pojedynczy pusty wynik nie są pełnym odbiorem. Nie przenosić forceDelete z diagnostyki na dowolne rekordy użytkownika.

Prywatny profil/CKAsset i lokalne cache/Keychain muszą zostać usunięte przez natywny klient po sprawdzeniu, że konto iCloud/tożsamość nie zmieniły się w trakcie. Serwer nie potwierdzi tego samodzielnie. Bez device acknowledgement zadanie nie ma completed. Po zamknięciu aplikacji musi dać się odzyskać bilet i dokończyć tę część; to nadal kryterium implementacji iOS.

## Ponowienia i nieznane wyniki

- Publiczna partia ma lease 60 s, trwały claim przed wyjściem z procesu i ponowienie idempotentnego adaptera po awarii. Błędów jest najwyżej 10 z backoff do 1 h; potem status attentionRequired i jawne wewnętrzne wznowienie przez operatora. Kod nie przedstawia tego jako zakończenia.
- Każdy zachowany credential, także pending tego samego zweryfikowanego sub, ma własny trwały lease. Revoke jest ponawiany do pięciu razy z backoff; w odróżnieniu od jednorazowego kodu autoryzacyjnego Apple dokumentuje puste 200 również dla tokenu wcześniej odwołanego. [Token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens).
- Ciphertext znika dopiero po potwierdzeniu odwołania lub rozstrzygnięciu manual-required. Brak klucza vault nie udaje odpowiedzi Apple. Po maksymalnie 7 dniach proces usuwa zachowane sekrety i wskazuje ręczne odwołanie. Awaria Apple nie blokuje kasowania danych publicznych.
- Zwykły purgeExpired nie usuwa credential objętego oczekującym odwołaniem. Żadne zadanie nie uruchamia płatnego rozszerzenia, nie kasuje konta Apple i nie dotyka dawnych danych Firebase.
- Ostateczne usunięcie auth wymaga usunięcia danych publicznych, potwierdzenia urządzenia, rozstrzygniętego stanu Apple, upływu okna i braku żywych rezerwacji. Następnie znikają sesje, granty, dowód Apple, credential, rezerwacje, zadania revoke i wiersz konta. Nowa świadoma rejestracja dostaje nowy UUID, bez odziedziczenia danych poprzedniego konta.

## Minimalne metadane bezpieczeństwa

Przez 30 dni od zakończenia pozostaje bilet/status i znacznik odcinający stare wyzwania; cleanup usuwa do 100 wpisów na wywołanie. Zadanie w toku nie jest zapominane razem z terminem statusu. To dane pseudonimowe, nie deklaracja anonimizacji.

Blokada operatora ma osobny skrót sub/czas w auth_subject_bans_v1. Usunięcie profilu i tożsamości nie kasuje tego znacznika i nie obchodzi moderacji przez ponowną rejestrację. Tymczasowe wyłączenie konta na czas erasure nie staje się banem, także po ponownym otwarciu bazy. Polityka retencji, przeglądu i odwołania blokad oraz informacja w UI/prywatności wymagają dopracowania przed publikacją; nie ma jeszcze panelu moderatora. Nie przechowujemy tu nazwy, e-maila, GPS, treści ani surowego sub Apple.

Metody job runnera, wznowienia operatora i finalizacji są wewnętrzne. Nie wystawiać dowolnego RPC z nazwą metody z JSON. Harmonogram, monitoring/obsługa przypadków attentionRequired i kontakt wsparcia nadal wymagają wdrożenia.

## Dowody i pozostały odbiór

**139/139 testów gateway**, w tym 23 nowe usuwania. Rzeczywiste SQLite, istniejący verifier RS256, syntetyczne klucze/JWT/odpowiedzi Apple oraz jawny testowy magazyn publicznych rekordów. Test 205 rekordów dowodzi sterowania partiami i izolacji właściciela w tym modelu, **nie działania CloudKit**. Testy obejmują utratę odpowiedzi, migrację starego magazynu, purpose/nonce, ban, warunki ukończenia części, timeout, SQL/sync, reopen, retry/backoff, późne lease/credential i brak odtworzenia starego konta. [Raport](evidence/account-deletion-local-tests.json).

Przed odbiorem pozostają rzeczywisty adapter CloudKit wraz z regułami własności/rejestrem zapisów, iOS/private cleanup/Keychain/zmiana konta, Apple revoke, zamknięte HTTP/alarm/limity, obsługa operatora i dwie zwykłe tożsamości. Aktualny Worker/bundler nie importuje nowych modułów; jego kod diagnostyczny i konfiguracja nie zmieniły się.
