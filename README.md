#  CPCTranslator

## Usage

CPCTranslator (this app) records audio, translates it into Ukrainian using the Microsoft Cognitive Services SDK, and writes it to stdout. I'm then piping it to the CPCTranslatorPublisher app which is a .Net app that publishes each translation event to an Azure Service Bus Queue, because it was easier to just do that in C# than in Swift. Also, Unix pipes make programs buffer output in ways that aren't conducive to the real-time publishing scenario we have here so I had to work around that. Thus, the way I've been invoking this is (from the XCode build directory):

`unbuffer ./CPCTranslator2 | dotnet ~/path/to/CPCTranslator.Publisher.dll`
