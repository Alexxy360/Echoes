# Poufna kolejka i odczyt zgłoszeń — CK-05c.1

19 listopada 2026. **Wewnętrzny odczyt zgłoszeń oraz późniejsze decyzje/recovery CK-05c.2 są zaimplementowane i sprawdzone lokalnie.** Nie ma jeszcze podłączonej trasy HTTP/Runtime ani panelu. Żadnej osobie nie nadano tym kodem dostępu. Poniżej opis historycznego CK-05c.1; [trwałe decyzje i granice](DECYZJE_ZGLOSZEN_I_ODZYSKIWANIE.md), [historyczne dowody odczytu](evidence/community-report-review-local-tests.json).

## Zakres

`CommunityReportReview` wymaga aktywnej natywnej sesji gateway, aktywnego konta operatora i osobnego synchronicznego `isOperator(accountID)`. Domyślnie zarówno funkcja, jak i rola odmawiają. Nie używa automatycznie roli moderatora zdjęć. Przyszła konfiguracja musi mieć osobną jawnie zatwierdzoną listę uprawnionych kont; obecnie żadnej nie zainstalowano.

`prepareQueue` zwraca jednorazowy finalizer strony do20zgłoszeń: reportID, createdAt, expiresAt i marker następnej strony. Kolejka nie zawiera powodów, tekstu wiadomości lub identyfikatora zgłaszającego. Korzysta ze zindeksowanych metadanych prywatnego SQLite i dokładnego keyset po reportID; nie wykonuje query typu w CloudKit. Rejestr sprawdza settled, aktywne konto autora zgłoszenia i termin30dni oraz stan retencji. Niepotwierdzone/pending, usuwane i wygasłe zgłoszenia pozostają ukryte.

`prepareInspection` przyjmuje tylko dokładny reportID. Istniejące repozytorium wykonuje uwierzytelniony lookup zgłoszenia i ewentualnie wskazanej wiadomości, sprawdza typ, owner/ID, tag, payload hash i dokładne pola. Odpowiedź zawiera powód zgłoszenia oraz dostępną treść wiadomości/pseudonim/autora. Nie zawiera ID zgłaszającego, GPS, utworów, pól profilu lub URL pliku. To uprzywilejowany odczyt moderatora: blokady i filtr użytkownika do3km nie uprawniają ani nie zastępują tej roli.

Nie utrwalamy dodatkowej kopii treści wiadomości w zgłoszeniu lub SQL. Wiadomość wygasła/usunięta/niepotwierdzona daje message=null, również jeżeli wygaśnie po przygotowaniu a przed zwróceniem wyniku. Nieobecne zgłoszenie lub utrata jego ważności zamyka cały odczyt. Późniejszy proces decyzji musi uwzględniać niedostępny materiał; ten etap nie przyznaje możliwości wydania decyzji bez treści.

## Granice asynchroniczne

Przed IO, po każdym await i przy finalizerze sprawdzane są aktywacja, sygnał, pierwotne konto/sesja operatora, jego rola i zegary. Rejestr jest sprawdzany także po końcowym checkpoint: usunięte zgłoszenie wypada ze strony, a stary wynik inspekcji nie ujawnia powodu. Pomyłki typów/treści i błędy providera są redagowane.

Jedna niezakończona operacja/finalizer na instancję, do8s, zegar ścienny i monotoniczny oraz ochrona cofnięcia czasu. Finalizer jest jednorazowy; porzucony wynik wygasa. Abort lub timeout zamyka dostęp, ale slot pozostaje zajęty do rzeczywistego zakończenia pracy i `client.waitForPendingOperations()`. Stary finalizer nie może zwolnić slotu nowego żądania. Nie jest to jeszcze limit globalny hostingu; HTTP wymaga osobnego admission/rate limits i końcowej kontroli odpowiedzi.

## Weryfikacja i dalsza praca

14nowych funkcji, pełne **705/705 Node22.23.5 i705/705 Node24.22.1**. Sprawdzono43zgłoszenia i strony20/20/3 bez query providera, ścisły osobny dostęp, dokładny odczyt bez GPS/reportera, podmienione pola i redakcję błędów, zmianę tożsamości/roli, usunięcie zgłoszenia przy finalizerze, wygaśnięcie wiadomości przed i po prepare, niepotwierdzone/wygasłe raporty, abort niekooperującego providera oraz stary finalizer podczas późniejszej operacji.

SQLite, podpisy i parser HTTP repozytorium są rzeczywiste; konta i CloudKit są jawnymi modelami. Istniejące testy lokalnego workerd pozostały zielone w pełnym zestawie, ale nowy koordynator nie jest jeszcze zainstalowany w Runtime. Rzeczywista osobna próba CK-05a.4h dotyczyła wyłącznie metadanych typów; nie potwierdza sesji moderatora, poufnego panelu lub A/B tego modułu.

Następnie: trwała intencja i wynik decyzji powiązany z obejrzanym materiałem/rewizją, ukrycie wiadomości lub zamknięcie zgłoszenia, idempotencja/recovery i audyt bez duplikowania treści; potem ograniczony HTTP/Runtime i natywny panel z osobnymi prawami. Zgłoszenia zdjęć, kontakt wsparcia („później”), pełny proces operatora oraz odbiór zwykłych kont/hostingu pozostają w planie. Nie przełączamy punktu wejścia ani nie odłączamy Firebase na podstawie lokalnego testu.
