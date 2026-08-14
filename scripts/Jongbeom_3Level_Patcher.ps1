param(
    [Parameter(Mandatory = $true)]
    [string]$SourceRoot
)

$ErrorActionPreference = 'Stop'

function Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

function Find-FunctionEnd {
    param(
        [string]$Text,
        [int]$OpenBraceIndex
    )

    $depth = 0
    $inString = $false
    $inChar = $false
    $inLineComment = $false
    $inBlockComment = $false
    $escape = $false

    for ($i = $OpenBraceIndex; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $n = if ($i + 1 -lt $Text.Length) { $Text[$i + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($c -eq "`n") { $inLineComment = $false }
            continue
        }

        if ($inBlockComment) {
            if ($c -eq '*' -and $n -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }

        if ($inString) {
            if ($escape) {
                $escape = $false
                continue
            }
            if ($c -eq '\') {
                $escape = $true
                continue
            }
            if ($c -eq '"') { $inString = $false }
            continue
        }

        if ($inChar) {
            if ($escape) {
                $escape = $false
                continue
            }
            if ($c -eq '\') {
                $escape = $true
                continue
            }
            if ($c -eq "'") { $inChar = $false }
            continue
        }

        if ($c -eq '/' -and $n -eq '/') {
            $inLineComment = $true
            $i++
            continue
        }

        if ($c -eq '/' -and $n -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }

        if ($c -eq '"') {
            $inString = $true
            continue
        }

        if ($c -eq "'") {
            $inChar = $true
            continue
        }

        if ($c -eq '{') {
            $depth++
            continue
        }

        if ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $i
            }
        }
    }

    return -1
}

function Replace-CppFunctionDefinition {
    param(
        [ref]$TextRef,
        [string]$DefinitionPattern,
        [string]$DisplayName,
        [string]$Replacement
    )

    $text = [string]$TextRef.Value
    $matches = [regex]::Matches(
        $text,
        $DefinitionPattern,
        [Text.RegularExpressions.RegexOptions]::Multiline
    )

    if ($matches.Count -ne 1) {
        throw "Expected exactly one FUNCTION DEFINITION for $DisplayName, found $($matches.Count)."
    }

    $start = $matches[0].Index
    $openBrace = $text.IndexOf('{', $start + $matches[0].Length - 1)

    if ($openBrace -lt 0) {
        throw "Opening brace was not found for $DisplayName."
    }

    $endBrace = Find-FunctionEnd -Text $text -OpenBraceIndex $openBrace
    if ($endBrace -lt 0) {
        throw "Closing brace was not found for $DisplayName."
    }

    $before = $text.Substring(0, $start)
    $after = $text.Substring($endBrace + 1)

    $TextRef.Value = $before + $Replacement.TrimEnd() + "`r`n" + $after
}

$sourceFile = Join-Path $SourceRoot 'src\osd\winui\treeview.cpp'
if (-not (Test-Path -LiteralPath $sourceFile)) {
    Fail ("treeview.cpp not found: " + $sourceFile)
    exit 10
}

Info ("Patching actual function definitions in: " + $sourceFile)
$cpp = [IO.File]::ReadAllText($sourceFile)

# ARCADE WinUI variants use either FI_CUSTOM or F_CUSTOM for the custom-folder flag.
# Detect the symbol from the checked-out source instead of hard-coding one release.
$headerCandidates = @(
    (Join-Path $SourceRoot 'src\osd\winui\treeview.h'),
    (Join-Path $SourceRoot 'src\osd\winui\winui.h')
)
$headerText = ''
foreach ($h in $headerCandidates) {
    if (Test-Path -LiteralPath $h) {
        $headerText += [IO.File]::ReadAllText($h) + "`n"
    }
}

$customFlag = $null
if ($headerText -match '(?m)^\s*FI_CUSTOM\s*(?:=|,)') {
    $customFlag = 'FI_CUSTOM'
}
elseif ($headerText -match '(?m)^\s*F_CUSTOM\s*(?:=|,)') {
    $customFlag = 'F_CUSTOM'
}
else {
    # Fallback: inspect the original source itself for the symbol used by custom folders.
    if ($cpp -match '\bFI_CUSTOM\b') {
        $customFlag = 'FI_CUSTOM'
    }
    elseif ($cpp -match '\bF_CUSTOM\b') {
        $customFlag = 'F_CUSTOM'
    }
}

if (-not $customFlag) {
    Fail 'Could not detect the custom-folder flag symbol (FI_CUSTOM/F_CUSTOM). Safe stop.'
    exit 13
}

Info ("Detected custom-folder flag: " + $customFlag)

if ($cpp.Contains('JONGBEOM_3LEVEL_PATCH_V2')) {
    Ok "Corrected 3-level patch is already present."
    exit 0
}

if ($cpp.Contains('JONGBEOM_3LEVEL_PATCH_V1')) {
    Fail "Broken V1 patch marker is present. Restore the original treeview.cpp before applying V2."
    exit 11
}

# Guard against accidentally patching a source that is not structurally compatible.
$requiredPrototype = 'static bool TryAddExtraFolderAndChildren(int parent_index);'
if (-not $cpp.Contains($requiredPrototype)) {
    Fail "Expected ARCADE custom-folder prototype was not found. Safe stop."
    exit 12
}

$tryAdd = @'
// JONGBEOM_3LEVEL_PATCH_V2
// Nested custom folder sections are expressed as [Parent/Child].
// Existing one-level custom INIs remain compatible.
bool TryAddExtraFolderAndChildren(int parent_index)
{
	char fname[MAX_PATH];
	char readbuf[256];
	char *name = NULL;
	LPTREEFOLDER lpTemp = NULL;
	LPTREEFOLDER lpFolder = treeFolders[parent_index];

	int current_id = lpFolder->m_nFolderId;
	int id = lpFolder->m_nFolderId - MAX_FOLDERS;
	snprintf(fname, std::size(fname), "%s\\%s.ini", GetFolderDir(), ExtraFolderData[id]->m_szTitle);
	FILE *f = fopen(fname, "r");

	if (f == NULL)
		return false;

	struct jongbeom_path_entry
	{
		char path[256];
		int folder_index;
	};

	const int max_path_entries = 1024;
	jongbeom_path_entry *path_entries =
		(jongbeom_path_entry *)calloc(max_path_entries, sizeof(jongbeom_path_entry));
	int path_count = 0;

	if (path_entries == NULL)
	{
		fclose(f);
		return false;
	}

	while (fgets(readbuf, 256, f))
	{
		if (readbuf[0] == '[')
		{
			char *p = strchr(readbuf, ']');

			if (p == NULL)
				continue;

			*p = '\0';
			name = &readbuf[1];

			if (strcmp(name, "FOLDER_SETTINGS") == 0)
			{
				current_id = -1;
				lpTemp = NULL;
				continue;
			}

			if (!strcmp(name, "ROOT_FOLDER"))
			{
				current_id = lpFolder->m_nFolderId;
				lpTemp = lpFolder;
				continue;
			}

			char section_path[256];
			snprintf(section_path, std::size(section_path), "%s", name);

			for (int c = 0; section_path[c]; c++)
				if (section_path[c] == '\\')
					section_path[c] = '/';

			while (section_path[0] == '/')
				memmove(section_path, section_path + 1, strlen(section_path));

			size_t section_len = strlen(section_path);
			while (section_len && section_path[section_len - 1] == '/')
				section_path[--section_len] = '\0';

			if (!section_path[0])
			{
				current_id = -1;
				lpTemp = NULL;
				continue;
			}

			char full_path[256];
			snprintf(full_path, std::size(full_path), "%s", section_path);

			char *last_slash = strrchr(section_path, '/');
			const char *folder_title = section_path;
			int actual_parent_index = parent_index;

			if (last_slash != NULL)
			{
				*last_slash = '\0';
				folder_title = last_slash + 1;

				bool parent_found = false;
				for (int pp = 0; pp < path_count; pp++)
				{
					if (core_stricmp(path_entries[pp].path, section_path) == 0)
					{
						actual_parent_index = path_entries[pp].folder_index;
						parent_found = true;
						break;
					}
				}

				if (!parent_found)
				{
					ErrorMessageBox(
						"Error parsing %s: parent section [%s] must appear before [%s]",
						fname, section_path, full_path);
					free(path_entries);
					fclose(f);
					return false;
				}
			}

			current_id = next_folder_id++;
			lpTemp = NewFolder(
				folder_title,
				current_id,
				actual_parent_index,
				ExtraFolderData[id]->m_nSubIconId,
				GetFolderFlags(numFolders) | __JONGBOEM_CUSTOM_FLAG__);

			AddFolder(lpTemp);
			int new_folder_index = numFolders - 1;

			if (path_count >= max_path_entries)
			{
				ErrorMessageBox("Too many nested custom folders in %s", fname);
				free(path_entries);
				fclose(f);
				return false;
			}

			snprintf(
				path_entries[path_count].path,
				std::size(path_entries[path_count].path),
				"%s",
				full_path);
			path_entries[path_count].folder_index = new_folder_index;
			path_count++;
		}
		else if (current_id != -1)
		{
			name = strtok(readbuf, " \t\r\n");

			if (name == NULL)
			{
				current_id = -1;
				continue;
			}

			for (int i = 0; name[i]; i++)
				name[i] = tolower(name[i]);

			if (lpTemp == NULL)
			{
				ErrorMessageBox(
					"Error parsing %s: missing [folder name] or [ROOT_FOLDER]",
					fname);
				current_id = lpFolder->m_nFolderId;
				lpTemp = lpFolder;
			}

			AddGame(lpTemp, GetGameNameIndex(name));
		}
	}

	free(path_entries);
	fclose(f);
	return true;
}
'@
$tryAdd = $tryAdd.Replace('__JONGBOEM_CUSTOM_FLAG__', $customFlag)

$resetTree = @'
// JONGBEOM_3LEVEL_PATCH_V2
// Keep the actual HTREEITEM for every TREEFOLDER, allowing arbitrary depth.
void ResetTreeViewFolders(void)
{
	HWND hTreeView = GetTreeView();
	TVITEM tvi;
	TVINSERTSTRUCT tvs;

	(void)TreeView_DeleteAllItems(hTreeView);

	HTREEITEM *folder_items =
		(HTREEITEM *)calloc(numFolders, sizeof(HTREEITEM));

	if (folder_items == NULL)
		return;

	for (int i = 0; i < numFolders; i++)
	{
		LPTREEFOLDER lpFolder = treeFolders[i];

		if (lpFolder->m_nParent == -1)
		{
			if (lpFolder->m_nFolderId < MAX_FOLDERS)
			{
				if (GetShowFolder(lpFolder->m_nFolderId) == false)
					continue;
			}

			tvs.hParent = TVI_ROOT;
			tvs.hInsertAfter = TVI_LAST;
		}
		else
		{
			int parent_index = lpFolder->m_nParent;

			if (parent_index < 0 || parent_index >= (int)numFolders)
				continue;

			if (folder_items[parent_index] == NULL)
				continue;

			tvs.hParent = folder_items[parent_index];
			tvs.hInsertAfter = TVI_SORT;
		}

		tvi.mask = TVIF_TEXT | TVIF_PARAM | TVIF_IMAGE | TVIF_SELECTEDIMAGE;
		tvi.pszText = lpFolder->m_lptTitle;
		tvi.lParam = (LPARAM)lpFolder;
		tvi.iImage = GetTreeViewIconIndex(lpFolder->m_nIconId);
		tvi.iSelectedImage = 0;
		tvs.item = tvi;

		folder_items[i] = TreeView_InsertItem(hTreeView, &tvs);
	}

	free(folder_items);
}
'@

$selectTree = @'
// JONGBEOM_3LEVEL_PATCH_V2
// Depth-first traversal that can climb any number of parent levels.
void SelectTreeViewFolder(int folder_id)
{
	HWND hTreeView = GetTreeView();
	HTREEITEM hti = TreeView_GetRoot(hTreeView);
	TVITEM tvi;

	memset(&tvi, 0, sizeof(TVITEM));

	while (hti != NULL)
	{
		tvi.hItem = hti;
		tvi.mask = TVIF_PARAM;
		(void)TreeView_GetItem(hTreeView, &tvi);

		if (((LPTREEFOLDER)tvi.lParam)->m_nFolderId == folder_id)
		{
			(void)TreeView_SelectItem(hTreeView, tvi.hItem);
			SetCurrentFolder((LPTREEFOLDER)tvi.lParam);
			return;
		}

		HTREEITEM next = TreeView_GetChild(hTreeView, hti);

		if (next != NULL)
		{
			hti = next;
			continue;
		}

		HTREEITEM cursor = hti;
		next = NULL;

		while (cursor != NULL)
		{
			next = TreeView_GetNextSibling(hTreeView, cursor);
			if (next != NULL)
				break;

			cursor = TreeView_GetParent(hTreeView, cursor);
		}

		hti = next;
	}

	tvi.hItem = TreeView_GetRoot(hTreeView);

	if (tvi.hItem != NULL)
	{
		tvi.mask = TVIF_PARAM;
		(void)TreeView_GetItem(hTreeView, &tvi);
		(void)TreeView_SelectItem(hTreeView, tvi.hItem);
		SetCurrentFolder((LPTREEFOLDER)tvi.lParam);
	}
}
'@

$saveExtra = @'
// JONGBEOM_3LEVEL_PATCH_V2
// Save all descendants using slash-separated section paths.
bool TrySaveExtraFolder(LPTREEFOLDER lpFolder)
{
	char fname[MAX_PATH];
	bool error = false;
	LPTREEFOLDER root_folder = NULL;
	LPEXFOLDERDATA extra_folder = NULL;

	int folder_index = -1;
	for (int i = 0; i < (int)numFolders; i++)
	{
		if (treeFolders[i] == lpFolder)
		{
			folder_index = i;
			break;
		}
	}

	if (folder_index < 0)
	{
		ErrorMessageBox("Error finding custom folder index to save");
		return false;
	}

	int root_index = folder_index;
	while (treeFolders[root_index]->m_nParent >= 0)
		root_index = treeFolders[root_index]->m_nParent;

	root_folder = treeFolders[root_index];

	for (int i = 0; i < numExtraFolders; i++)
	{
		if (ExtraFolderData[i] &&
			ExtraFolderData[i]->m_nFolderId == root_folder->m_nFolderId)
		{
			extra_folder = ExtraFolderData[i];
			break;
		}
	}

	if (extra_folder == NULL || root_folder == NULL)
	{
		ErrorMessageBox("Error finding custom file name to save");
		return false;
	}

	snprintf(
		fname,
		std::size(fname),
		"%s\\%s.ini",
		GetFolderDir(),
		extra_folder->m_szTitle);

	wchar_t *temp = win_wstring_from_utf8(GetFolderDir());
	CreateDirectory(temp, NULL);
	free(temp);

	FILE *f = fopen(fname, "w");

	if (f == NULL)
		error = true;
	else
	{
		fprintf(f, "[FOLDER_SETTINGS]\n");

		if (extra_folder->m_nIconId < 0)
			fprintf(
				f,
				"RootFolderIcon %s\n",
				ExtraFolderIcons[(-extra_folder->m_nIconId) - ICON_MAX]);

		if (extra_folder->m_nSubIconId < 0)
			fprintf(
				f,
				"SubFolderIcon %s\n",
				ExtraFolderIcons[(-extra_folder->m_nSubIconId) - ICON_MAX]);

		fprintf(f, "\n[ROOT_FOLDER]\n");

		for (int i = 0; i < driver_list::total(); i++)
			if (TestBit(root_folder->m_lpGameBits, i))
				fprintf(f, "%s\n", GetDriverGameName(i));

		for (int j = 0; j < (int)numFolders; j++)
		{
			if (j == root_index)
				continue;

			int chain[64];
			int depth = 0;
			int cursor = j;

			while (cursor >= 0 && cursor != root_index && depth < 64)
			{
				chain[depth++] = cursor;
				cursor = treeFolders[cursor]->m_nParent;
			}

			if (cursor != root_index || depth == 0)
				continue;

			fprintf(f, "\n[");

			for (int d = depth - 1; d >= 0; d--)
			{
				fprintf(f, "%s", treeFolders[chain[d]]->m_lpTitle);
				if (d != 0)
					fprintf(f, "/");
			}

			fprintf(f, "]\n");

			for (int i = 0; i < driver_list::total(); i++)
				if (TestBit(treeFolders[j]->m_lpGameBits, i))
					fprintf(f, "%s\n", GetDriverGameName(i));
		}

		fclose(f);
	}

	if (error)
		ErrorMessageBox("Error while saving custom file %s", fname);

	return !error;
}
'@

try {
    Replace-CppFunctionDefinition `
        -TextRef ([ref]$cpp) `
        -DefinitionPattern '^bool\s+TryAddExtraFolderAndChildren\(int parent_index\)\s*\r?\n\{' `
        -DisplayName 'TryAddExtraFolderAndChildren' `
        -Replacement $tryAdd

    Replace-CppFunctionDefinition `
        -TextRef ([ref]$cpp) `
        -DefinitionPattern '^void\s+ResetTreeViewFolders\(void\)\s*\r?\n\{' `
        -DisplayName 'ResetTreeViewFolders' `
        -Replacement $resetTree

    Replace-CppFunctionDefinition `
        -TextRef ([ref]$cpp) `
        -DefinitionPattern '^void\s+SelectTreeViewFolder\(int folder_id\)\s*\r?\n\{' `
        -DisplayName 'SelectTreeViewFolder' `
        -Replacement $selectTree

    Replace-CppFunctionDefinition `
        -TextRef ([ref]$cpp) `
        -DefinitionPattern '^bool\s+TrySaveExtraFolder\(LPTREEFOLDER lpFolder\)\s*\r?\n\{' `
        -DisplayName 'TrySaveExtraFolder' `
        -Replacement $saveExtra
}
catch {
    Fail $_.Exception.Message
    exit 20
}

# Strong structural verification: prototype remains; each real definition exists once.
$checks = @(
    @{ Name='TryAdd definition'; Pattern='(?m)^bool\s+TryAddExtraFolderAndChildren\(int parent_index\)\s*\r?\n\{' },
    @{ Name='Reset definition'; Pattern='(?m)^void\s+ResetTreeViewFolders\(void\)\s*\r?\n\{' },
    @{ Name='Select definition'; Pattern='(?m)^void\s+SelectTreeViewFolder\(int folder_id\)\s*\r?\n\{' },
    @{ Name='Save definition'; Pattern='(?m)^bool\s+TrySaveExtraFolder\(LPTREEFOLDER lpFolder\)\s*\r?\n\{' }
)

foreach ($check in $checks) {
    $count = ([regex]::Matches($cpp, $check.Pattern)).Count
    if ($count -ne 1) {
        Fail ($check.Name + " count is " + $count + ", expected 1.")
        exit 21
    }
}

$markerCount = ([regex]::Matches($cpp, 'JONGBEOM_3LEVEL_PATCH_V2')).Count
if ($markerCount -ne 4) {
    Fail ("Patch marker count is " + $markerCount + ", expected 4.")
    exit 22
}

if (-not $cpp.Contains($requiredPrototype)) {
    Fail "The original forward declaration was accidentally removed."
    exit 23
}

$backup = $sourceFile + '.before_jongbeom_v2'
if (-not (Test-Path -LiteralPath $backup)) {
    Copy-Item -LiteralPath $sourceFile -Destination $backup -Force
}

[IO.File]::WriteAllText(
    $sourceFile,
    $cpp,
    (New-Object Text.UTF8Encoding($false))
)

Ok "Corrected 3-level tree patch V2 applied and structurally verified."
exit 0
