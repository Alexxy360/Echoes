# Trwałe decyzje zgłoszeń i odzyskiwanie — CK-05c.2

19 listopada 2026. Wewnętrzny serwis obsługuje inspekcję, decyzję i sprawdzenie nieznanego wyniku. **Późniejszy CK-05c.3 podłączył ograniczone HTTP/Runtime i wykonał lokalny odbiór; panel i rzeczywista aktywacja pozostają do wykonania.** W CK-05c.2 nie aktywowano uprawnień moderatora ani usługi i nie wykonano nowej próby Apple. Administracyjna rola właściciela z CK-05a.4h pozostaje przypisana. [HTTP i granice](HTTP_POUFNYCH_ZGLOSZEN.md), [historyczne dowody lokalne](evidence/community-report-decisions-local-tests.json).

## Inspekcja i decyzja

`CommunityReportReviewState` działa w tym samym prywatnym SQLite co rejestr, sesje i `CommunityState`. Inspekcja zapisuje przed odpowiedzią krótkotrwałe potwierdzenie związane z operatorem, skrótem jego konkretnej sesji, zgłoszeniem i wersją materiału. Zawiera wyłącznie metadane i skrót zobowiązania: dokładne ID/tag/hash/intencję zgłoszenia oraz dostępnej wiadomości i terminy. Bez powodów, tekstu, pseudonimów, GPS, tokenów sesji lub dodatkowego snapshotu treści.

Potwierdzenie ważne jest do90s, najwyżej do terminu zgłoszenia. Jeden wpis na operatora, maks256wpisów. Zaczęcie następnej inspekcji zastępuje wcześniejszą. Osobny trwały budżet10inspekcji/min/operator nie znika wraz ze skasowaniem potwierdzenia; przechowuje tylko hash moderatora i licznik do końca kolejnej minuty. Budżet również ograniczony do256wierszy. Cofnięty zegar lub niespójne metadane zamykają dostęp.

Potwierdzenie jest oznaczane jako zweryfikowane po poprawnym odczycie materiału przez serwer, przed końcową odpowiedzią. **Nie dowodzi obejrzenia treści przez człowieka.** Natywny panel musi pokazać materiał i uzyskać świadomą decyzję oraz zapisać jej intencję przed wysłaniem. Tego odbioru UI jeszcze nie wykonano.

`prepareDecision` przyjmuje wyłącznie inspectionID, decisionID i verdict oraz natywną sesję. Właściciel/operator nie pochodzi z pól klienta. Obsługiwane decyzje:

- `dismiss`: zamknięcie zgłoszenia bez zmiany widoczności wiadomości.
- `hide_message`: zamknięcie zgłoszenia i ukrycie dokładnie zgłoszonej wiadomości w projekcji polityki.

Serwis ponownie odczytuje zgłoszenie i wiadomość przez istniejące repozytorium, sprawdza dokładne pola/tag/hash oraz porównuje zobowiązanie z potwierdzeniem. Zmieniony, wygasły lub usunięty materiał wymaga nowej inspekcji. Gdy wiadomość jest niedostępna, nowa inspekcja pozwala tylko na dismiss; nie odtwarza starego tekstu. Nie dodano cofania ukrycia, banowania kont ani odrzucania dowolnego ID podanego przez klienta.

## Atomowy skutek i idempotencja

Bezpośrednio przed transakcją wymagane jest synchroniczne `authorize() === true`. False, brak wyniku i Promise są odrzucane. Brak await między tą kontrolą a transakcją zapobiega wywołaniu zagnieżdżonych transakcji autoryzacji. Wewnątrz transakcji sprawdzamy ponownie lokalny stan zgłoszenia/retencji oraz dokładny rekord wiadomości i zatwierdzoną intencję `CommunityState`.

Ukrycie przez `hidden=1` oraz wpis decyzji powstają **w jednej transakcji**. Awaria inserta wycofuje też ukrycie. Jest jeden wynik na zgłoszenie, z decisionID, verdict, nową rewizją UUID, skrótem materiału/operatora i czasem, bez kopii treści. Dokładne ponowienie zachowuje tę samą rewizję. Inny verdict, decisionID, operator lub materiał nie nadpisuje decyzji; ponowne użycie decisionID dla innego zgłoszenia również jest odrzucane. Dwa konkurujące rozstrzygnięcia mają jednego zwycięzcę. Zamknięte zgłoszenie wypada z kolejki i nie przyjmuje nowej inspekcji.

Po transakcji wymagane są sync SQLite, aktualna autoryzacja oraz końcowy checkpoint. Wynik jest sprawdzany ponownie przez jednorazowy finalizer. Utrata roli, anulowanie lub błąd po commicie może zablokować odpowiedź, choć skutek już zaszedł; nie przedstawiamy tego jako cofnięcia decyzji. Ukrycie jest wymuszane przez istniejącą serwerową politykę odczytu, bez fizycznego kasowania wiadomości w CloudKit.

## Odzyskiwanie i retencja

`prepareRecovery` wymaga aktywnego osobno uprawnionego operatora i dokładnego reportID/decisionID/verdict/contentHash. Sprawdza trwałość i istniejący wynik, bez nowej decyzji:

- `confirmed`: dokładna decyzja tego operatora i jej niezmienna rewizja.
- `not-applied`: brak zastosowanej decyzji dla nadal ważnego zgłoszenia.
- `superseded`: istnieje inne rozstrzygnięcie; odpowiedź nie przyznaje cudzej rewizji.

Nowa sesja tego samego operatora może sprawdzić wynik po wygaśnięciu potwierdzenia inspekcji. Nie może nim ponownie autoryzować mutacji. Usunięte/wygasłe zgłoszenie nie udostępnia recovery. Przyszły klient musi zachować nierozstrzygniętą intencję do autorytatywnego sprawdzenia; nie zmieniać jej ID lub verdict po timeout.

Lokalny alarm usuwa do256nieaktualnych potwierdzeń i do100decyzji na przebieg po wygaśnięciu lub utracie zgłoszenia/konta autora. Decyzja wygasa razem ze zgłoszeniem, najpóźniej po jego30dniach; nie odnawia tego terminu. Osobny budżet wygasa niezależnie w ciągu dwóch minut. Sprzątanie nie cofa ukrycia i nie kontaktuje się z dostawcą. Budzenie uwzględnia najbliższy termin oraz pozostałe wpisy do sprzątnięcia; same decyzje nie wymuszają pustego alarmu co minutę przez30dni. Rejestr ma dotychczasowy limit10000rekordów; jeden wynik na zarejestrowane zgłoszenie mieści się w tym ograniczeniu.

## Weryfikacja i granice

21nowych funkcji testowych. Pełne **726/726 Node22.23.5 i726/726 Node24.22.1**. SQLite, transakcje, plik/reopen, podpisy i parser repozytorium są rzeczywiste; konta i odpowiedzi Apple modelowane. Sprawdzono dokładne decyzje/retry/recovery, brak treści w SQL, wygaśnięcie i zastąpienie inspekcji, zmianę sesji/operatora, niedostępną wiadomość, błąd SQL po hidden i utratę ACK po commicie, późną utratę roli, konkurujące rozstrzygnięcia, niezależny limit, unverified/async/false authorization, ponowne ID oraz alarm po usunięciu zgłoszenia. Prawdziwy plik SQLite po reopen zwrócił tę samą rewizję bez potwierdzenia inspekcji lub sieci. Nie jest to test utraty zasilania lub PITR hostingu.

Istniejące testy workerd pozostały zielone; nowy proces decyzji nie jest jeszcze zainstalowany w prawdziwym Runtime/HTTP lub odebrany przez realnego moderatora. Następne: ograniczone trasy i jawna konfiguracja operatorów, walidacja/admission/limity obu warstw HTTP, natywny kontrakt/panel/dziennik/recovery oraz rzeczywiste sesje i A/B. Zgłoszenia zdjęć, kontakt wsparcia i pozostałe odbiory pełnej migracji nadal wymagane. Bez nowych kluczy/ról, wdrożenia, opłat, iOS/Firebase/Production/TestFlight.
