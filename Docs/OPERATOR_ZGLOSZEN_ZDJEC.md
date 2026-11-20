# Obsługa zgłoszonych zdjęć — CK-05d.2

Stan: CK-05d.2a zaimplementowany i odebrany lokalnie. To wewnętrzny magazyn metadanych, bez nowych tras, operatorów lub aktywacji. [Plan zgłoszeń](ZGLOSZENIA_ZDJEC_PLAN.md).

## Kolejność

1. **2a — obecny etap:** trwały snapshot/receipt, atomowy zapis decyzji i odcięcie dokładnej publikacji, readonly recovery, kolejka, retencja i erasure.
2. **2b — zaufany koordynator:** rola ze zweryfikowanej sesji przed/po IO, poufny powód i dokładny nadal opublikowany pełny obraz przez chroniony download/manifest/hash. Rezerwacja przed kosztem dostawcy, confirm dopiero po walidacji; brak oryginału pozwala tylko dismiss. Retained IO/drain,8s,checkpoint i jednorazowy finalizer. Własna rzeczywista lokalna integracja workerd.
3. **2c — zamknięte HTTP/Runtime:** domyślnie wyłączone flagi/pusta lista moderatorów, limity przed body/checkpoint/provider, ścisłe odpowiedzi i końcowy guard. Metadata/powód i obraz muszą być związane z tym samym receipt; dokładny protokół transportu zostanie zamknięty przed implementacją. Bez aktywacji/sekretów.
4. **2d — iOS:** typowany transport, trwała intencja przed mutacją, aktualne dekodowanie/wyświetlenie, osobna zgoda moderatora, foreground/native/private/parent/expiry i readonly recovery bez ponownej decyzji; testy UI.
5. Wszystkie rzeczywiste odbiory pełnego planu, w tym CloudKit/SIWA/hosting/Free/zwykłe A/B i urządzenie. Kontakt właściciel poda później.

## Kontrakt wewnętrzny 2a

AvatarReportReviewState przechowuje osobne tabele inspekcji, decyzji i budżetów SQLite. Snapshot wiąże zamknięty raport/tag/hash/request i pierwotne30dni z avatarID/versionID/generacją/SHA oraz opcjonalnym dokładnym wyborem autora/revision/tagami avatara i wskaźnika. Hash raportu wiąże również powód bez jego duplikowania. Nie zapisuje się powodu, pikseli, GPS, tokenów, URL/receipt dostawcy lub kopii profilu.

Receipt ma90s od rezerwacji (krócej przy terminie raportu), jeden wpis na reviewer,256 globalnie i10 nowych/min. Pierwszy zapis jest niezweryfikowany. Zaufane confirm jest miejscem dla przyszłego dowodu chronionego IO, nie dowodem oglądu w tym etapie. Nowy receipt, inna sesja/operator lub cofnięcie poniżej czasu rezerwacji wycofuje stary. Decide wymaga dokładnie synchronicznego true z guard i aktywnego reviewer; Promise/truthy/undefined/wyjątek odmawiają. Magazyn nie uwierzytelnia bearer ani nie nadaje roli. Koordynator2b musi to zrobić przed/po await i w finalizerze.

Dismiss zamyka tylko zgłoszenie. Hide_photo wymaga nadal approved/published dokładnej wersji/generacji/revision, ważnej zgody, aktywnego autora, gotowego wskaźnika i zgodnych registry rekordów, kanonicznego descriptor/hash oraz braku retirement. Zmiana zdjęcia, clear, nowa moderacja albo tag odmawiają. Odrzucenie job, nowa moderation revision, ready=0/pointer_tag=NULL i niezmienna decyzja raportu są jedną transakcją. Błąd INSERT cofa również odcięcie publikacji. Nie ma approved→pending lub automatycznej nowej kolejki. Istniejąca polityka odcina stare publish leases i odczyty. Nie jest to fizyczne usunięcie ASSET u Apple ani cofnięcie już pobranych pikseli.

Ta sama decyzja/reviewer/content/verdict odtwarza wynik bez nowej mutacji; konflikt ID/verdict/operator odmawia. Readonly recovery zwraca historyczne confirmed/not-applied/superseded, również po wygaśnięciu inspekcji, ale w terminie istniejącego raportu. Confirmed oznacza zapis konkretnej decyzji, nie obietnicę stanu zdjęcia po przyszłych działaniach. Unknown nie uruchamia nowej mutacji.

reviewAvatarReportPage używa lokalnego keyset/index, do20 zeskanowanych rekordów i markera postępu, bez queries dostawcy/treści raportu. Kolejka wiadomości jest osobna. Cancelling/cancelled, expiry i wyłączone konto zgłaszającego nie są kandydatami;2b doda filtrowanie rozstrzygniętych decyzji i finalizer. Maintenance usuwa do256 inspekcji/100 decyzji oraz budżety, wyznacza wake. Erasure w istniejącej disabled-owner transakcji usuwa związane metadata moderatora/zgłaszającego/znanego autora i zachowuje niezwiązane wpisy. Cleanup nie przywraca zdjęcia. Nowe tabele i indeks są lokalne; schema CloudKit niezmieniony.

## Odbiór i granice

20 nowych funkcji; finalne870/870 na Node22.23.5 i24.22.1, składnia188MJS obu. Kolejka43, niezweryfikowany receipt/sesje, ścisły guard, zmiany revision/tagów/descriptor/generacji, konflikt dwóch modelowanych reviewer, rollback/lostACK, expiry/cancel i selektywne erasure. Prawdziwy plik SQLite otwarto drugim połączeniem w tym samym procesie; nie jest to restart procesu/power-loss/PITR. Negatywna kopia bez kontroli moderation revision oblewa1test/1asercję; oryginał zachowany.

Pierwszy focus nie załadował źle nazwanego eksportu; drugi15/16 miał zły klucz authorize fixture i poprawną odmowę PUBLIC_SCOPE. Poprawiono nazwę/fixture. Pierwszy pełny870Node22 był zielony; po przeglądzie dodano indeks i kontrolę target_owner, oba finały powtórzono. [Wyniki i SHA](evidence/avatar-report-review-state-local-tests.json).

Dostawcy/konta i confirm są modelowane. Pełny zestaw obejmuje wcześniejsze workerd, lecz nowy stan wymaga własnego odbioru workerd/hostingu. iOS/Core/deps/CI niezmienione i niepowtarzane. Bez nowych uprawnień/kluczy/sekretów/usług/opłat/SDK telefonu/Apple/Cloudflare/Production/Firebase/TestFlight. Zastany projekt zachowany. Migracja trwa;2b–2d i rzeczywiste odbiory pozostają obowiązkowe.
