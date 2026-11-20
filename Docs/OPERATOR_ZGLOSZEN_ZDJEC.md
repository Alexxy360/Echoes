# Obsługa zgłoszonych zdjęć — CK-05d.2

Stan: CK-05d.2a–2c zaimplementowane i odebrane lokalnie. Kod obejmuje magazyn, koordynator i zamknięte API; usługi pozostają nieaktywne, bez przypisanych moderatorów. Panel natywny2d jest kolejną częścią. [Plan zgłoszeń](ZGLOSZENIA_ZDJEC_PLAN.md).

## Kolejność

1. **2a — lokalnie odebrany:** trwały snapshot/receipt, atomowy zapis decyzji i odcięcie dokładnej publikacji, readonly recovery, kolejka, retencja i erasure.
2. **2b — lokalnie odebrany koordynator:** rola ze zweryfikowanej sesji przed/po IO, poufny powód i dokładny nadal opublikowany pełny obraz przez chroniony download/manifest/hash. Rezerwacja przed avatar/CDN po metadanych raportu, confirm dopiero po walidacji; brak oryginału pozwala tylko dismiss. Retained IO/drain,8s,checkpoint i jednorazowy finalizer. Własna rzeczywista lokalna integracja workerd.
3. **2c — lokalnie odebrane HTTP/Runtime:** domyślnie wyłączone flagi/pusta lista moderatorów, limity przed body/checkpoint/provider, ścisłe odpowiedzi i końcowy guard. Metadata/powód i obraz są związane z tym samym receipt w jednej zamkniętej ramce HTTP. Bez aktywacji/sekretów.
4. **2d — iOS:** typowany transport, trwała intencja przed mutacją, aktualne dekodowanie/wyświetlenie, osobna zgoda moderatora, foreground/native/private/parent/expiry i readonly recovery bez ponownej decyzji; testy UI.
5. Wszystkie rzeczywiste odbiory pełnego planu, w tym CloudKit/SIWA/hosting/Free/zwykłe A/B i urządzenie. Kontakt właściciel poda później.

## Kontrakt wewnętrzny 2a

AvatarReportReviewState przechowuje osobne tabele inspekcji, decyzji i budżetów SQLite. Snapshot wiąże zamknięty raport/tag/hash/request i pierwotne30dni z avatarID/versionID/generacją/SHA oraz opcjonalnym dokładnym wyborem autora/revision/tagami avatara i wskaźnika. Hash raportu wiąże również powód bez jego duplikowania. Nie zapisuje się powodu, pikseli, GPS, tokenów, URL/receipt dostawcy lub kopii profilu.

Receipt ma90s od rezerwacji (krócej przy terminie raportu), jeden wpis na reviewer,256 globalnie i10 nowych/min. Pierwszy zapis jest niezweryfikowany. Zaufane confirm jest miejscem dla przyszłego dowodu chronionego IO, nie dowodem oglądu w tym etapie. Nowy receipt, inna sesja/operator lub cofnięcie poniżej czasu rezerwacji wycofuje stary. Decide wymaga dokładnie synchronicznego true z guard i aktywnego reviewer; Promise/truthy/undefined/wyjątek odmawiają. Magazyn nie uwierzytelnia bearer ani nie nadaje roli. Koordynator2b musi to zrobić przed/po await i w finalizerze.

Dismiss zamyka tylko zgłoszenie. Hide_photo wymaga nadal approved/published dokładnej wersji/generacji/revision, ważnej zgody, aktywnego autora, gotowego wskaźnika i zgodnych registry rekordów, kanonicznego descriptor/hash oraz braku retirement. Zmiana zdjęcia, clear, nowa moderacja albo tag odmawiają. Odrzucenie job, nowa moderation revision, ready=0/pointer_tag=NULL i niezmienna decyzja raportu są jedną transakcją. Błąd INSERT cofa również odcięcie publikacji. Nie ma approved→pending lub automatycznej nowej kolejki. Istniejąca polityka odcina stare publish leases i odczyty. Nie jest to fizyczne usunięcie ASSET u Apple ani cofnięcie już pobranych pikseli.

Ta sama decyzja/reviewer/content/verdict odtwarza wynik bez nowej mutacji; konflikt ID/verdict/operator odmawia. Readonly recovery zwraca historyczne confirmed/not-applied/superseded, również po wygaśnięciu inspekcji, ale w terminie istniejącego raportu. Confirmed oznacza zapis konkretnej decyzji, nie obietnicę stanu zdjęcia po przyszłych działaniach. Unknown nie uruchamia nowej mutacji.

reviewAvatarReportPage używa lokalnego keyset/index, do20 zeskanowanych rekordów i markera postępu, bez queries dostawcy/treści raportu. Kolejka wiadomości jest osobna. Cancelling/cancelled, expiry i wyłączone konto zgłaszającego nie są kandydatami;2b doda filtrowanie rozstrzygniętych decyzji i finalizer. Maintenance usuwa do256 inspekcji/100 decyzji oraz budżety, wyznacza wake. Erasure w istniejącej disabled-owner transakcji usuwa związane metadata moderatora/zgłaszającego/znanego autora i zachowuje niezwiązane wpisy. Cleanup nie przywraca zdjęcia. Nowe tabele i indeks są lokalne; schema CloudKit niezmieniony.

## Odbiór 2a — stan przed połączeniem koordynatora

20 nowych funkcji; finalne870/870 na Node22.23.5 i24.22.1, składnia188MJS obu. Kolejka43, niezweryfikowany receipt/sesje, ścisły guard, zmiany revision/tagów/descriptor/generacji, konflikt dwóch modelowanych reviewer, rollback/lostACK, expiry/cancel i selektywne erasure. Prawdziwy plik SQLite otwarto drugim połączeniem w tym samym procesie; nie jest to restart procesu/power-loss/PITR. Negatywna kopia bez kontroli moderation revision oblewa1test/1asercję; oryginał zachowany.

Pierwszy focus nie załadował źle nazwanego eksportu; drugi15/16 miał zły klucz authorize fixture i poprawną odmowę PUBLIC_SCOPE. Poprawiono nazwę/fixture. Pierwszy pełny870Node22 był zielony; po przeglądzie dodano indeks i kontrolę target_owner, oba finały powtórzono. [Wyniki i SHA](evidence/avatar-report-review-state-local-tests.json).

Dostawcy/konta i confirm są modelowane. W etapie2a nowy stan nie miał własnego odbioru workerd; późniejszy lokalny odbiór2b opisano niżej. Hosting nadal nieodebrany. iOS/Core/deps/CI niezmienione i niepowtarzane. Bez nowych uprawnień/kluczy/sekretów/usług/opłat/SDK telefonu/Apple/Cloudflare/Production/Firebase/TestFlight. Zastany projekt zachowany. Migracja trwa; postęp2b opisano niżej,2c/2d i rzeczywiste odbiory pozostają obowiązkowe.


## CK-05d.2b — odbiór koordynatora przed podłączeniem2c

AvatarReportReviewCoordinator jest domyślnie wyłączony i odmawia zwykłym kontom. Używa zweryfikowanego authorize i synchronicznego serwerowego predykatu roli, bez uprawnień z JSON. Konto/skrót sesji, aktywność oraz flaga i rola są sprawdzane po await i w jednorazowym finalizerze. Nawet ten sam bearer zaczynający wskazywać inne uprawnione konto nie dziedziczy przygotowanego materiału.

Kolejka keyset filtruje rozstrzygnięte oraz wycofane raporty również po ostatnim checkpoint. Inspekcja najpierw odczytuje i weryfikuje niezmienny raport/payload hash. Autora rozwiązuje wyłącznie przez registry avatara z raportu; klient nie dostarcza owner/version/URL. Brak aktualnej dokładnej publikacji daje null target. Nigdy nie wybiera się nowego zdjęcia w zastępstwie. Rezerwacja receipt następuje po odczycie metadanych raportu/checkpoint, ale przed odczytem avatara/CDN. Nie jest to quota przed każdym żądaniem dostawcy; limity przed całym request doda2c. getReserved kontroluje unverified podczas IO i nie pozwala decide.

Dla obecnego oryginału ponownie sprawdzane są pointer, registry, wersja/generacja/revision, descriptor i oba asset commitments. Wspólny chroniony download wymusza dokładne zaufane hosty Apple, HTTPS, manual redirect, omit credentials i dwa nagłówki; bounded256000B/128chunks, SHA i wymiary/JPEG. Confirm następuje po walidacji, scope i trwałym zapisie/checkpoint. To serwerowy dowód IO, nie oglądu człowieka; przyszłe iOS musi zdekodować i faktycznie wyświetlić obraz przed zgodą.

NOT_FOUND rekordu lub dokładny CDN404/410 nie potwierdzają dawnego receipt. Tworzony jest nowy dismiss-only z null target (druga rezerwacja/quota), a poprzedni pozostaje wycofany. Przekierowanie, błędny manifest/hash, inny status lub błąd sieci odmawiają. Taki brak materiału nigdy nie daje hide_photo. Nowy receipt i wynik są kontrolowane po IO; zmiana publikacji lub cancel w trakcie odcina przygotowanie.

Wewnętrzny finalizer zwraca {metadata,image}: poufny powód, daty, content hash, receipt i opcjonalny manifest/identyfikację dokładnej fotografii oraz kopię JPEG albo null. Bez reporterID/GPS/URL/receipts dostawcy. Nie jest jeszcze formatem HTTP. Zaufany odbiorca ma natychmiast synchronicznie skonsumować/zakodować kopię i wyczyścić ją w finally. Przygotowany oryginał jest czyszczony przy finalizacji lub abort; nie oznacza to wyzerowania wszystkich kopii systemowych RAM. Brak magazynu zdjęć w receipt.

Nowa decyzja wymaga verified receipt, aktualnego raportu i zgodnego snapshotu przed atomowym efektem2a. Gdy ta sama decyzja jest już confirmed, jawny replay odtwarza wynik bez drugiego hide/pobrania. Scope i historyczny outcome są ponownie sprawdzane po trwałym IO i końcowym checkpoint. Readonly recovery nie potrzebuje zdjęcia lub nowej inspekcji i działa po90s, w terminie raportu.

Jeden slot jest zachowany do rzeczywistego zakończenia CloudKit/fetch/body i pierwszego cancel, nawet po zwróceniu błędu wywołującemu. Deadline8s, wall/monotonic floors i timer odcinają wynik. Nieznany/nieudany drain zamyka scope; stary finalizer nie zwalnia nowej operacji. Nie ma automatycznego odświeżania lub mutacji.

24 nowe funkcje (23 unit i1 realny lokalny workerd), finalne894/894 Node22.23.5 i894/894 Node24.22.1; syntax193MJS obu. Lokalny workerd/DO SQLite rzeczywiście wykonuje podpisany public client, chroniony JPEG, odcięcie zwykłego konta/roli, atomowe rejected, exact replay i readonly recovery po odtworzeniu koordynatora/state i wygaśnięciu receipt. Apple/CDN/konta są modelowane, outbound zablokowany; ta sama baza/proces, nie restart/power-loss/PITR/hosted Free. Negatywna kopia bez porównania przechwyconej tożsamości oblewa1test/1asercję. Początkowy focus40/41 poprawiono przez właściwy klucz modelu imageSha256; pierwszy workerd model błędnie wymagał właściwości Request.credentials — poprawiono tylko fixture, zachowując omit i zamknięte nagłówki produktu. [Dowody i SHA](evidence/avatar-report-review-coordinator-local-tests.json).

HTTP/Runtime i natywny panel dla tego nowego procesu nadal niewdrożone. Brak iOS/Core/deps/CI i ich ponowień, nowych uprawnień/kluczy/sekretów/usług/opłat/SDK telefonu/Apple/Cloudflare/Production/Firebase/TestFlight. Zastany projekt zachowany; wszystkie rzeczywiste odbiory pełnego planu nadal wymagane.


## CK-05d.2c — zamknięte HTTP i Runtime

Wdrożono lokalnie cztery osobne trasy, ramkę4B metadata-length + UTF8 JSON + JPEG, ścisłe walidatory obu granic, role/limity przed body w Authority oraz retained8/12/15s. Default0/pusta lista; READ/upload/intake/inna moderacja są niezależne. Finalne909/909 obu Node, syntax199MJS/2JSON, rzeczywisty lokalny workerd edge/Runtime/SQLite/frame/decision/recovery i negatywna kontrola byteCount. [Kontrakt i ograniczenia](HTTP_OPERATORA_ZGLOSZEN_ZDJEC.md), [dowody](evidence/avatar-report-review-http-local-tests.json).

Następny2d: natywny typowany transport ramki, metadata-only intencja decyzji przed mutacją, host z prawdziwym dekodowaniem/wyświetleniem i jawnym potwierdzeniem, recovery bez nowej decyzji, panel i lifecycle/erasure/UI. Następnie wszystkie rzeczywiste odbiory pełnego planu. Nie aktywowano usług, praw, sekretów, opłat lub TestFlight.
