# CK-04e.3j.3c.4c.3 — podgląd autora i osobne potwierdzenie publikacji

Kontrolowany natywny edytor potrafi pobrać własne zatwierdzone zdjęcie bez dawnego upload journala, wyświetlić dokładny obraz i uzyskać osobne potwierdzenie publikacji. Ten sam wymóg obejmuje zdjęcia po bieżącym uploadzie. Odczyt, faktyczne wyświetlenie i potwierdzenie to osobne czynności; sam status approved lub lokalny szkic nie otwierają publikacji.

## Host i granice obrazu

GatewayAvatarOwnerPreviewHost używa [osobnego API autora](NATYWNY_PODGLAD_ZDJECIA_AUTORA.md). Ma kontekst natywnej autoryzacji, prywatnego scope, parent callback i foreground oraz własną epokę. Początkowo jest nieaktywny i poza foreground. Runtime przekazuje go do istniejącego GatewayAvatarEditorHost; oba uwzględniają pracę podglądu we wspólnym busy. Nie zmieniono zwykłego wejścia Firebase ani aktywacji serwera.

Przed i po oczekiwaniu na token/API/dekodowanie host sprawdza kontekst. Potwierdza też pełne query, origin, fingerprint bearer, manifest i wymiary. Nieważną sesję przekazuje do głównej autoryzacji wyłącznie przy nadal zgodnym kontekście; spóźniona odmowa starego konta nie wylogowuje nowego. Nie przechowuje JPEG na dysku/Keychain lub we wspólnym cache. Interfejs otrzymuje opaque, redacted, Hashable handle. Każde renderowanie ponownie rozwiązuje go przez image(for:); CGImage nie trafia do @State. Wygasły, stary lub obcy handle nie daje obrazu ani prawa potwierdzenia.

Ważność pozostaje nieodnawialnymi 30 s od rozpoczęcia sieci, z oboma zegarami i kontrolą rollback. Lokalny timer zmienia obserwowalną revision i usuwa obraz bez poll/refresh; gettery niezależnie sprawdzają ważność. Zamknięcie, tło i native invalidation kasują lokalne presentation/ACK. Powrót do foreground nie odtwarza poprzedniego obrazu. Caller ma obowiązek synchronicznie przekazywać bariery konta, prywatnego scope i parent — same gettery nie zastępują tych sygnałów ani nie wykrywają zdalnych zmian bez nowego RPC.

Jeden slot obejmuje także credentials, API i decode; po invalidate/cancel pozostaje zajęty do rzeczywistego powrotu zależności. Nowy ekran nie dostaje spóźnionego wyniku. Kontekst potomka przechwytuje niezmienny wybór/sessionID i słabo host edytora; nie utrzymuje sesji widoku w cyklu pamięci.

## Potwierdzenie i trwała intencja

Edytor udostępnia podgląd wyłącznie dla aktualnego approved i zgodnego lokalnego wpisu albo pustego magazynu. Dopuszczalne są dokładny staged upload lub dokładna zachowana intencja publish; clear, niepewny upload i inny wybór odmawiają. Niewysłany lokalny draft blokuje podgląd starszego zdjęcia z serwera. Przygotowanie nowego pliku i wszystkie inne operacje edytora, w tym refresh, odcinają poprzedni podgląd i ACK.

Przycisk pobrania wywołuje wyłącznie odczyt. Obraz ma jawne oznaczenie dostępności i identyfikator także poza Form. Widok używa onScrollVisibilityChange(threshold: 0.9): ACK wymaga widoczności co najmniej 90% obrazu w viewport, następnego przebiegu task, aktywnej sceny i nadal zgodnego handle. Samo utworzenie obrazu poza ekranem nie daje ACK. Aplikacja już ma deployment target iOS 26.1; pakiet bez SwiftUI zachowuje swój wcześniejszy target. Znaczenie progu opisuje [Apple](https://developer.apple.com/documentation/swiftui/view/onscrollvisibilitychange(threshold:_:)). To lokalny display ACK — nie dowód widzenia obrazu przez człowieka ani uprawnienie serwerowe.

Dopiero po ACK pojawia się przejście do osobnego przewijanego potwierdzenia w tym samym NavigationStack. Ekran pokazuje ten sam handle i zdjęcie, tekst zgody, Anuluj oraz Potwierdź publikację zdjęcia. Wygaśnięcie usuwa obraz i blokuje przycisk; trzeba wrócić i jawnie pobrać podgląd ponownie. Anulowanie nie publikuje ani nie tworzy intencji.

Ostateczna czynność confirmPublication(handle) wymaga nadal zgodnego approved/obrazu/ACK. Host zużywa handle przed await, uzyskuje świeży token i ponownie sprawdza binding oraz czas. Błąd tego kroku wymaga nowego podglądu. Edytor po powrocie sprawdza własny kontekst i niezmienny wybór, a następnie przekazuje dokładny intent do nowego publish(selected:) sterownika. Nie przechwytuje w tym miejscu innego snapshotu. Sterownik nadal odczytuje świeży serwerowy status, zachowuje generation/reviewRevision, trwale zapisuje prepared/publishing i dopiero potem wysyła HTTP.

Stare perform(.publish) w edytorze zawsze odmawia; nie jest obejściem nowej ścieżki. Publiczne API niższego sterownika pozostaje narzędziem zaufanego kodu, nie dowodem ludzkiej zgody. Serwer zawsze niezależnie autoryzuje właściciela i dokładny wybór; zmodyfikowany klient nie może zastąpić wyboru nową decyzją moderacji, ale samego obejrzenia obrazu nie da się udowodnić takim API.

Po niepewnym wyniku pozostaje [intencja metadanych](PUBLIKACJA_METADANYCH_IOS.md), bez JPEG. Recover jest tylko odczytem i niczego nie publikuje. Jeżeli wynik pozostaje approved, jawne ponowienie wymaga nowego aktualnego obrazu, ACK i osobnego potwierdzenia, zachowując dokładne zapisane ID/revision. Sam approved nadal nie dowodzi historycznej porażki poprzedniej próby. Clear pozostaje autorytatywnym wycofaniem.

## Walidacja i ograniczenia

[Raport etapu](evidence/avatar-owner-publication-ui-local-tests.json) zawiera rzeczywiste wyniki, SHA kodu/logów/zrzutów i zakres kontroli negatywnej. Testy hosta obejmują display ACK i jednorazowe zużycie, konta/prywatny scope/parent/scene, stare handle, oba zegary, timer bez poll, retained slot, spóźnione odpowiedzi i potwierdzenie blokowane przez credentials. Testy edytora obejmują źródłowo pusty magazyn, staged upload, dokładny publish intent, nową rewizję serwera, unknown/recover/jawny retry, draft, zamknięcie, scope i zwalnianie sesji/hosta.

Scenariusze interfejsu wykorzystują rzeczywistą aplikację/SwiftUI/edytor/HTTP klient/dekoder/journal na symulatorze, ze zdjęciem i tożsamościami syntetycznymi. Dodano osobne fixtures dla istniejącego approved/pending bez lokalnego uploadu oraz izolowane #Preview dla obu stanów. Nie są to testy rzeczywistego gateway/CloudKit, hosted Free, SIWA, dwóch zwykłych kont, restartu procesu po awarii ani fizycznego Keychain/FileProtection/PhotosPicker/iCloud Photos.

Kontrolowany Runtime jest połączony, ale realny odbiór nadal wymaga właściwych schematów/ról/hostów i oddzielnej tożsamości serwisowej, konfiguracji darmowego środowiska oraz A/B. Nie wykonano wdrożenia, aktywacji, zmiany usług/kluczy/uprawnień/opłat, SDK telefonu, Production/Firebase/TestFlight. Zastana zmiana projektu Xcode pozostaje zachowana. Wcześniejsze ostrzeżenia ramek SwiftUI i pozostałe części planu nadal wymagają odbioru przed TestFlight.


Końcowe dowody lokalne: pakiet556 zdefiniowanych/554 zaliczone+2 sprzętowe pominięcia na obu platformach,22 nowe funkcje testowe i15 plików strict format; Debug oraz niepodpisany Release poprawne.14 różnych UI przyjęto z udokumentowanych przebiegów, a nie jako pojedynczy końcowy run14/14: siedem niezmienionych przypadków z pierwszej regresji, sześć zaliczonych po progu viewport i końcowe dwa testy zwykłego/największego tekstu (jeden powtórzony). Wcześniejsze błędy obejmowały dostępność obrazu, brak ponownego otwarcia zamkniętej sesji, wygaśnięcie starego podglądu po anulowaniu i gesty startujące na stałych przyciskach. Końcowy gest jest oparty na zmierzonym viewport nad przyciskami; asercje wymagają pełnego obrazu w jego granicach. Kontrola negatywna bez display ACK oblewa1 test z2 problemami. W końcowym dużym tekście nadal występuje ostrzeżenie Invalid frame dimension; jego przyczyna nie została udowodniona.

Dalsza diagnoza ostrzeżenia ramek: [UI-01](KLAWIATURA_I_DUZY_TEKST_IOS.md) wskazał pasek klawiatury ustawień. Po jego zastąpieniu ponowiono również powyższy scenariusz publikacji przy największym tekście; przeszedł bez ostrzeżenia. Nie zmienia to historycznych wyników etapu ani pozostałych bramek migracji.
