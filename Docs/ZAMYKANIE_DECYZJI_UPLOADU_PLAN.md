# Zamykanie niepewnych decyzji o uploadzie — CK-05d.2c.2

Stan: dodatkowy problem potwierdzony lokalnie podczas odbioru2c.1; poprawka jeszcze niewdrożona. To oddzielny panel oceny nowych uploadów approved/rejected, a nie zgłoszeń społeczności. Przed natywnym panelem zgłoszonych zdjęć2d i przed aktywacją wymagany jest ten sam kontrakt zamykania prób.

## Dowód i znaczenie

Lokalny rzeczywisty edge/Authority/Runtime/SQLite z syntetycznym providerem: queue → inspect → recover(not-applied) → opóźnione decide(rejected) tej samej próby → recover(confirmed). Decyzja została zastosowana po wcześniejszym odczycie braku. publishedVersionID pozostał null: sama ocena uploadu nie publikuje zdjęcia za autora. Nie wykonano operacji na Apple/Cloudflare/urządzeniu lub prawdziwym koncie. Wynik i SHA skryptu/logu są w [dowodach2c.1](evidence/moderation-retirement-local-tests.json).

GatewayAvatarReviewJournal nadal traktuje notApplied jako resolved. Host emituje resolved także wtedy, co zwalnia lokalną barierę moderacji przed świeżym chronionym odczytem. Taki odczyt nadal podlega serwerowi, ale nie może zastępować dowodu zamknięcia dawnej, nadal ważnej próby. Nie uznajemy tego przepływu za odebrany w ramach2c.1.

## Kolejność

1. Osobny minimalny trwały rejestr własnego moderatora/UUID i hasha pełnej siedmiopolowej intencji: accountID/requestID/versionID/generation/reviewRevision/decisionID/verdict. Uwzględnić istniejącą tożsamość operatora i domenę; bez obrazu, URL lub tokenu. Nie adaptować na siłę identyfikatorów raportów do uploadu.
2. Jawne retire odczytuje znaną decyzję albo utrwala blokadę. **AvatarPolicy.review musi sprawdzać blokadę w swojej transakcji efektu**, nie tylko wcześniej w koordynatorze lub claim receipt. Wymusić wyścig już po claim i podczas provider/IO. Zamknięcie nie odrzuca całego joba i nie przywraca zdjęcia. Powtórny wybór wymaga nowej inspekcji/intencji.
3. Zachować istniejące role, domyślne wyłączenie, limity/deadline/drain oraz checkpoint/finalizer. Recovery pozostaje readonly. Terminalne wyniki retired/confirmed/superseded; żadnego automatycznego retire po timeout. Bounded capacity/expiry/alarm i selektywne usuwanie właściciela lub moderatora, z testem niewpływania na inne konta.
4. Natywny journal: legacy resolved/not-applied → nierozstrzygnięty z tym samym UUID, brak ACK; retiring przed IO, terminalny dowód po zapisie, utrata ACK/restart bez decide retry. Zachować lokalną barierę publikacji dla nieostatecznego wyniku, także przy otwarciu mapy bez panelu. Zwolnienie terminalnej bariery dopuszcza wyłącznie nowy chroniony odczyt; nie przywraca pikseli, zgody autora ani publikacji.
5. UI z odrębnym anulowalnym potwierdzeniem zamknięcia i komunikatem bez twierdzenia o cofnięciu lub historycznym niewykonaniu. Konto/tło/rodzic/expiry, AX XXXL, opóźnione odpowiedzi i prawdziwy restart procesu muszą mieć odbiór. Oddzielić syntetyczny storage od rzeczywistego Keychain.
6. Odpowiednie testy SQLite/Runtime/workerd i native/Keychain/UI/Debug/Release, test negatywny kontroli bezpośrednio przed efektem oraz klienta z nieostateczną odpowiedzią. Dowody, dziennik i plan w tym samym commicie, potem push i weryfikacja HEAD. Dalej wrócić do2d i pełnych rzeczywistych bramek odbioru.

Brak automatycznego rozszerzenia zdalnych zgód, nowych schematów CloudKit, ról/kluczy/sekretów/usług/opłat, Production/Firebase/TestFlight lub fizycznego urządzenia. Zwykłe A/B, SIWA, ASSET/CDN, alarmy/Free i urządzenia pozostają rzeczywistymi warunkami całej migracji.
