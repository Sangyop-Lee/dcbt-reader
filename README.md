# DCBT Reader

Digitized Chinese Buddhist Text Reader — a Mac app for searching and reading the
CBETA edition of the Chinese Buddhist canon.

The app itself contains no texts and no dictionary. It reads them from the
folders that sit beside it, which you fill yourself:

| Folder | What goes in it | Needed? |
|---|---|---|
| `Source texts` | CBETA's XML files | Yes |
| `Dictionaries` | StarDict or Babylon dictionaries, such as 漢語大詞典 | Only for dictionary lookup |
| `Language model` | The BGE-M3 model for "By meaning" search | Only for search by meaning |
| `Gaiji` | CBETA's font and glyph images for rare characters | Recommended |
| `SLR files` | CBReader "limited search" range files (`.slr`) | Optional |

Keep `DCBT Reader.app` and these folders together in one folder.

## Getting started

**Requirements:** a Mac with Apple silicon and macOS 15 or later.

1. Get the app. Either download `DCBT Reader.app` from the Releases page of
   this repository and put it in this folder, or build it yourself:
   `App Source/build.sh` (needs Apple's Command Line Tools, installed with
   `xcode-select --install`; Xcode itself is not required).
2. Get the texts: `App Source/tools/fetch_texts.sh` downloads the Taishō and
   Xuzangjing from CBETA (section 1 below has the details and other ways).
3. Recommended: `App Source/tools/fetch_gaiji.sh` downloads CBETA's files for
   rare characters (section 4).
4. Optional: add dictionaries (section 2), the language model for search by
   meaning (section 3), and an API key for translation (section 5).
5. Open the app. The first launch builds the search index.

The app is not signed with an Apple developer certificate. The first time you
open a downloaded copy, macOS may refuse; right-click the app and choose
**Open**, or allow it under System Settings ▸ Privacy & Security. A copy you
build yourself opens normally.

## 1. Getting the texts from CBETA

CBETA publishes its texts as TEI XML at <https://github.com/cbeta-org/xml-p5>.
The repository has one folder per canon: `T` (Taishō), `X` (Xuzangjing),
`J` (Jiaxing), `A`, `B`, `K` and so on. Take whichever you want; the app works
with any selection.

**With the script:** `App Source/tools/fetch_texts.sh` downloads the Taishō and
Xuzangjing into `Source texts`. Name other canons to get those instead, for
example `App Source/tools/fetch_texts.sh T X J`.

**With git** (in Terminal):

```bash
git clone --depth 1 https://github.com/cbeta-org/xml-p5.git
```

Then copy the canon folders you want (for example `T` and `X`) into
`Source texts`, so that you have `Source texts/T/T01/T01n0001.xml` and so on.

**Without git:** open the repository page, press **Code ▸ Download ZIP**,
unpack it, and copy the canon folders into `Source texts`. The whole
repository is large (several GB unpacked); the Taishō and Xuzangjing together
are about 1.5 GB.

The first time the app opens it reads the XML and builds its search index
(about 10 seconds for the Taishō and Xuzangjing). After adding, removing or
updating XML files, choose **Library ▸ Rebuild Search Index**.

CBETA's texts are free for non-commercial use; see
<https://www.cbeta.org/copyright.php>.

## 2. Adding dictionaries

Selecting up to four characters in the text looks them up in the dictionaries
in the `Dictionaries` folder. The app is distributed without any, because
dictionaries such as 漢語大詞典 are under copyright. You supply your own.

**What the app accepts**

- **StarDict** dictionaries: a set of three files with the same name
  (`name.ifo`, `name.idx`, and `name.dict` or `name.dict.dz`). Put them in the
  folder as those files (in a sub-folder if you like), or as the single archive
  you downloaded, unopened: `.tar.bz2`, `.tbz`, `.trz`, `.tar.gz`, `.tgz`,
  `.zip`, `.7z` and a bare `.bz2` all work.
- **Babylon** dictionaries: a single `.bgl` file.

You can add as many as you like. **DCBT Reader ▸ Dictionary Settings** (or the
gear in the Dictionary tab) lists what is in the folder; tick the ones to use.
A lookup shows the entry from each ticked dictionary, one after another, in
the order of that list; the arrows beside each dictionary move it up or down.
Press **Rescan** there after adding a file.

Each dictionary is prepared once, into the app's own data folder, and your
file is left untouched.

**Finding them**

- 漢語大詞典: StarDict editions have circulated for many years. Search for
  `StarDict 漢語大詞典` or `stardict 汉语大词典`, or for the file name
  `stardict-chibigenc-2.4.2.tar.bz2` (an edition titled "汉语大词典 离线版",
  about 350,000 entries with traditional-character headwords, roughly 70 MB).
  Collections of StarDict dictionaries made for readers such as GoldenDict or
  KOReader are another place to look.
- Buddhist glossaries: Dharma Drum's DILA publishes Seishi Karashima's
  glossaries of the Lotus Sūtra translations and other reference works as
  Babylon `.bgl` and StarDict files under a Creative Commons licence; see
  <https://glossaries.dila.edu.tw>. The Soothill–Hodous and Ding Fubao
  dictionaries also exist in StarDict form.
- Other formats (MDict `.mdx`, Apple `.dictionary`) are not read directly;
  tools such as *pyglossary* convert them to StarDict.

Whether you may use a particular copy depends on its copyright status and the
law where you live. That is for you to check; the app only reads what you give it.

## 3. Search by meaning (optional)

`Language model` holds BAAI's BGE-M3 model converted for the Mac
(`bge-m3.mlmodelc`, 1.1 GB, MIT licence) and its vocabulary. With it, the
**By meaning** button finds passages similar in meaning to what you type,
including from an English query. Before a text can be searched this way the
model has to read it: press **Build for Texts in Scope** under the search
field. The whole Taishō and Xuzangjing take several hours per passage size.
The model file is too large for the repository. Either download
`Language model.zip` from the Releases page and unpack it here, or build it
with `App Source/tools/build_model.sh`, which downloads BGE-M3 from Hugging
Face (2.3 GB) and converts it; that needs Python 3 and about 12 GB of free
disk space while it runs. Without this folder the app falls back to the Mac's
built-in language model, which is much weaker.

## 4. Rare characters

`Gaiji` holds CBETA's supplementary font and its glyph images for characters
that are not in Unicode, from <https://github.com/cbeta-org/cbeta-fonts>,
`gaiji-CB`, `sd-gif` and `rj-gif`. `App Source/tools/fetch_gaiji.sh` downloads
and packs them. Without this folder such characters show as
boxes or as composition formulas like `[金*本]`. CBETA provides the font for
non-commercial and personal research use.

## 5. Translation (optional)

Selecting five or more characters opens the Translation tab with the passage;
pressing **Translate** there translates it into Korean or English
through OpenAI, Anthropic or Google, using an API key of your own that you
enter in **DCBT Reader ▸ Translation Settings** (⌘,). Keys are stored in the
Mac's keychain. The selected passage is sent to the company you chose.

Every translation, every dictionary lookup and every search is added to a
plain-text log. The tray buttons in the Translation and Dictionary tabs open
those logs; clicking the search box lists your last 20 searches, with the full
search log one click further. The logs are records only: nothing is read back
from them, so they can grow, be edited or be deleted freely.

## Where the app keeps its own data

`~/Library/Application Support/DCBT Reader/`

| Item | Contents |
|---|---|
| `index/` | the search index (rebuilt from the XML at any time) |
| `semantic/` | the by-meaning indexes, one folder per passage size |
| `Dictionary cache/` | the prepared dictionaries |
| `bookmarks.json` | your bookmarks |
| `Search log.txt`, `Dictionary log.txt`, `Translation log.txt` | what you searched, looked up and translated, one entry per line |

Deleting `index`, `semantic` or `Dictionary cache` is safe; the app rebuilds them.

## Copying a passage with its citation

Select a passage in the reader and choose **Edit ▸ Copy with Citation** (⇧⌘C),
the quotation-mark button above the text, or right-click the selection. What
is copied looks like this:

    『菩薩地持經』卷5「菩薩地持方便處戒品之餘」：若[36]彼[37]聞已向惡人說[38]破壞正法。 (T1581, 30:914a29–b1)
    [36]彼＝知【宮】。[37]聞＝知【宋】【元】【明】。[38]〔破壞正法〕－【聖】【知】。

The quoted text is always that of the printed edition (the Taishō or the
Xuzangjing), whichever edition is on screen: where CBETA corrected a
character, the printed character is restored and the correction is reported
as a variant of 【CB】. The note numbers are those of the printed footnotes.

The chapter is given as the text itself prints its heading, number and all
(釋迦內外族姓名譜第七, 序品第一, 戒品之餘 at the head of a later fascicle); the
app adds no numbering of its own. Where headings are nested, every printed
level is given in order, each in its own brackets:
『釋迦譜』卷1「釋迦四部名聞弟子譜第九」「名聞優婆塞四十人」. The outline CBETA
adds to some texts (its 章 and 節), which is not printed, is left out.

**Citation Format…** (in the app menu, or the arrow beside the button) sets
how this is written. Drag the pieces to reorder them, drag new ones in from
the shelf (title, fascicle, chapter, quoted text, canon, text number, volume,
page, column, line, variant notes, or fixed text), click a piece to set the
characters before and after it and the language it is written in (T, Taishō,
大正藏, 대정장; a b c, 上 中 下, 상 중 하; 5 or 五), and tick the editions the
variant notes should report. Besides the wordings in the menu, "My own
wording…" lets you type your own for the canon and the columns.

Give a format a name and press **Save Format** to keep it; any number of
formats can be saved. The menu at the top of the sheet, and the arrow beside
the quotation-mark button, switch between them, and the same menu offers
ready-made examples to start from: the forms used in
*T'oung Pao*, *Philosophy East and West*, *JAOS*, *The Eastern Buddhist*, *Buddhist Studies
Review* and 『印度学仏教学研究』, and Chinese and Korean conventions.
Check a journal's current guidelines before submitting; house styles change. The format in use is remembered between launches.

## Comparing two texts

The overlapping-rectangles button above the text (or a right-click on a text
in the list) compares the text being read with another one you choose by
title or number. Every run of three or more characters that the two texts
share is tinted in the text: faintly for three characters, more strongly for
each character more, up to eight or longer. Punctuation and line breaks are
ignored, and titles, headings, bylines and catalogue lines are left out. The menu beside the button sets the shortest run to show (3+ … 8+):
three catches stock phrases as well, five or six shows mostly real parallels.

Pointing at a tinted passage draws a box round the longest passage the two
texts share at that spot; clicking it searches the other text for that
passage and lists the places in the results column.

The button carrying the other text's title takes you to that text, at the
passage it shares with the place you were reading, with the comparison turned
round; the same button there brings you back. **File ▸ Open Another DCBT
Reader** (⌘N) starts a second copy of the app, so the two texts can also be
read side by side. Copies share settings, bookmarks and logs.

## Building from source

`App Source/build.sh` compiles the Swift sources in `App Source/Sources` with
the command-line `swiftc` (Xcode is not required) and writes
`DCBT Reader.app` beside the folders above.

## What is in this repository

Only the app's source (`App Source`), these instructions, and empty folders
for the data. CBETA's texts and rare-character files, dictionaries and the
language model are downloaded by each user and are not redistributed here;
`.gitignore` keeps them out.

## Licence

The source code is released under the MIT licence; see `LICENSE`. The licence
covers this app only. CBETA's texts and fonts, the dictionaries and the
BGE-M3 model each keep their own terms.
