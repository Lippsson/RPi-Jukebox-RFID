#!/usr/bin/env python3
"""
Playlists are build from directory content in the following way:
a directory is parsed and files are added to the playlist in the following way

1. files are added in alphabetic order
2. files ending with ``*livestream.txt`` are unpacked and the containing URL(s) are added verbatim to the playlist
3. files ending with ``*podcast.txt`` are unpacked and the containing Podcast URL(s) are expanded and added to the playlist
4. files ending with ``*.m3u`` are treated as folder playlist. Regular folder processing is suspended and the playlist
   is build solely from the ``*.m3u`` content. Only the alphabetically first ``*.m3u`` is processed. URLs are added verbatim
   to the playlist except for ``*.xml`` and ``*.podcast`` URLS, which are expanded first

An directory may contain a mixed set of files and multiple ``*.txt`` files, e.g.

.. code-block:: bash

    01-livestream.txt
    02-livestream.txt
    music.mp3
    podcast.txt

All files are treated as music files and are added to the playlist, except those:

 * starting with ``.``,
 * ending with ``.txt``,
 * ending with ``.m3u``,
 * ending with one of the excluded file endings in :attr:`PlaylistCollector._exclude_endings`

In recursive mode, the playlist is generated by concatenating all sub-folder playlists. Sub-folders are parsed
in alphabetic order. Symbolic links are being followed. The above rules are enforced on a per-folder bases.
This means, one ``*.m3u`` file per sub-folder is processed (if present).

In ``*.txt`` and ``*.m3u`` files, all lines starting with ``#`` are ignored.

"""
# Some developers notes:
# So far this is only for MPD (no spotify)
#
# It is not planned to support mopidy (we use something different for spotify). If ever only the
# self.default_handler would need to be replaced
# to add add(local:track:filename") and not only add "filename" (with also probably some encoding)
#
# Generally speaking, the decode..() functions below do decoding and formatting of file entries
# The most general solution would be to split that. Use an intermediate format based on a NamedTuple which
# contains the URI and the type of URI (where it was parsed from). After playlist has been collected, run a formatter
# that formats the NamedTuple to URI strings according to player
# This also does not consider a mixed player setup (mpd/spotify)
import copy
import os
import os.path
import logging
import re
import requests

from typing import (List)

logger = logging.getLogger('jb.plgen')

# From .xml podcasts, need to parse out these strings:
# '<enclosure url="https://podcast-mp3.dradio.de/podcast/2020/07/19/balzen_flirten_liebhaben_wie_tiere_fuer_nachwuchs_drk_20200719_0730_0126ac2f.mp3" length="19204101" type="audio/mpeg"/>'  # noqa: E501
enclosure_re = re.compile(r'.*enclosure.*url="([^"]*)"')


def decode_podcast_core(url, playlist):
    # Example url:
    # url = 'http://www.kakadu.de/podcast-kakadu.2730.de.podcast.xml'
    # url = 'https://www1.wdr.de/mediathek/audio/hoerspiel-speicher/wdr_hoerspielspeicher150.podcast'
    try:
        r = requests.get(url)
    except Exception as e:
        logger.error(f"Get URL: {e.__class__.__name__}: {e}")
        return
    if r.status_code != 200:
        logger.error(f"Got error code {r.status_code} fetching from '{url}'")
    er = enclosure_re.findall(r.content.decode(r.encoding))
    if len(er) == 0:
        logger.error(f"Zero file entries in parsed content from '{url}'")
    for exp in er:
        # print(f"{exp}")
        playlist.append(exp)


def decode_podcast(filename: str, path, playlist):
    logger.debug(f"Decode podcast: '{filename}'")
    with open(filename) as f:
        for line in f:
            line = line.strip()
            if len(line) > 0 and not line.startswith('#'):
                decode_podcast_core(line, playlist)


def decode_livestream(filename: os.DirEntry, path, playlist):
    logger.debug(f"Decode livestream: '{filename}'")
    with open(filename.path) as f:
        for line in f:
            line = line.strip()
            if len(line) > 0 and not line.startswith('#'):
                playlist.append(line)


def decode_musicfile(filename: os.DirEntry, path, playlist):
    playlist.append(os.path.normpath(os.path.join(path, filename.name)))


def decode_m3u(filename: os.DirEntry, path, playlist: List[str]):
    logger.debug(f"Decode M3U '{filename.path}'. Replacing current (sub-)folder playlist")
    playlist.clear()
    with open(filename.path) as f:
        for line in f:
            line = line.strip()
            if len(line) > 0 and not line.startswith('#'):
                # TODO: Improve Podcast / URL detection
                if line.endswith(".xml") or line.endswith(".podcast"):
                    decode_podcast(line, path, playlist)
                elif line.startswith('http://') or line.startswith('https://') or line.startswith('ftp://'):
                    playlist.append(line)
                else:
                    playlist.append(os.path.normpath(os.path.join(path, line)))
    # Returning True stops further processing on this directory
    return True


class PlaylistCollector:
    """
    Build a playlist from directory(s)

    This class is intended to be used with an absolute path to the music library::

        plc = PlaylistCollector('/home/chris/music')
        plc.parse('Traumfaenger')
        print(f"res = {plc}")

    But it can also be used with relative paths from current working directory::

        plc = PlaylistCollector('.')
        plc.parse('../../../../music/Traumfaenger')
        print(f"res = {plc}")

    The file ending exclusion list :attr:`PlaylistCollector._exclude_endings` is a class variable for performance reasons.
    If changed it will affect all instances. For modifications always call :func:`set_exclusion_endings`.

    """
    # There are two paths variables:
    # - (a) the full directory path
    # - (b) the relative directory path from the music_library_base_path
    # We need to
    # - search path (a)
    # - add to the playlist: b/filename

    #: Ignore files with the following endings.
    #: Attention: this will go into a regexp builder, i.e. ``.*`` will match anything!
    #: Always set via :func:`set_exclusion_endings`
    _exclude_endings = ['zip', 'py', 'db', 'png', 'jpg', 'conf', 'yaml', 'json', '.*~', '.*#']
    # Will generate a regex pattern string like this: r'.*\.((txt)|(zip))$
    _exclude_str = '.*\\.((' + ')|('.join(_exclude_endings) + '))$'
    _exclude_re = re.compile(_exclude_str, re.IGNORECASE)

    def __init__(self, music_library_base_path='/'):
        """
        Initialize the playlist generator with music_library_base_path

        :param music_library_base_path: Base path the the music library. This is used to locate the file in the disk
        but is omitted when generating the playlist entries. I.e. all files in the playlist are relative to this base dir
        """
        self.playlist = []
        self._music_library_base_path = os.path.abspath(music_library_base_path)
        # These two variables only store reference content to generate __str__
        self._folder = ''
        self._recursive = False

        logger.debug(f"Exclusion regex: '{PlaylistCollector._exclude_str}'")

        # Special handlers are processed top-down, allowing specialization of file-endings
        self.special_handlers = {'livestream.txt': decode_livestream,
                                 'podcast.txt': decode_podcast,
                                 # Ignore all other .txt files
                                 '.txt': lambda f, p, l: None,
                                 '.m3u': decode_m3u}
        self.default_handler = decode_musicfile

    @classmethod
    def _is_valid(cls, direntry: os.DirEntry) -> bool:
        """
        Check if filename is valid
        """
        return direntry.is_file() and not direntry.name.startswith('.') \
               and PlaylistCollector._exclude_re.match(direntry.name) is None

    @classmethod
    def set_exclusion_endings(cls, endings: List[str]):
        """Set the class-wide file ending exclusion list

        See :attr:`PlaylistCollector._exclude_endings`"""
        cls._exclude_endings = copy.deepcopy(endings)
        # Will generate a regex pattern string like this: r'.*\.((txt)|(zip))$
        cls._exclude_str = '.*\\.((' + ')|('.join(cls._exclude_endings) + '))$'
        cls._exclude_re = re.compile(cls._exclude_str, re.IGNORECASE)

    def _parse_nonrecusive(self, path='.'):
        folder_playlist = []
        directory = filter(PlaylistCollector._is_valid, os.scandir(path))
        # Sort the directory content (case in-sensitive) to give reproducible results across different machines
        # And do this before parsing special content files. Reason: If there is a special content file (e.g. podcast)
        # which links to multiple streams, these will already be ordered
        directory = sorted(directory, key=lambda x: x.name.casefold())
        stop_processing = False
        for filename in directory:
            if stop_processing:
                break
            # print(f"{filename.name}")
            for key in self.special_handlers.keys():
                if filename.name.casefold().endswith(key):
                    # Some handlers will disallow processing the remaining directory contents
                    # Save this information for the outer loop
                    stop_processing = self.special_handlers[key](filename, path, folder_playlist)
                    # Stop search though valid handlers on first match
                    break
            else:
                # No special handler for this file
                self.default_handler(filename, path, folder_playlist)
        return folder_playlist

    def _parse_recursive(self, path='.'):
        # This can certainly be optimized, as os.walk is called on all
        # directories and _parse_nonrecusive does a call to os.scandir for each directory
        # But I want the directory list to be ordered. And it works :-)
        recursive_playlist = []
        dir_list = []
        for directories, _, filenames in os.walk(path, followlinks=True):
            dir_list.append(directories)
        dir_list = [d for d in dir_list]
        for d in sorted(dir_list, key=lambda x: x.casefold()):
            recursive_playlist = [*recursive_playlist, *(self._parse_nonrecusive(d))]
        return recursive_playlist

    def parse(self, path='.', recursive=False):
        """Parse the folder ``path`` and create a playlist from it's content

        :param path: Path to folder **relative** to ``music_library_base_path``
        :param recursive: Parse folder recursivley, or stay in top-level folder
        """
        self.playlist = []
        self._recursive = recursive
        self._folder = os.path.abspath(os.path.join(self._music_library_base_path, path))
        func = self._parse_recursive if recursive else self._parse_nonrecusive
        try:
            self.playlist = func(self._folder)
        except NotADirectoryError as e:
            logger.error(f" {e.__class__.__name__}: {e}")
        except FileNotFoundError as e:
            logger.error(f" {e.__class__.__name__}: {e}")

    def __iter__(self):
        return self.playlist.__iter__()

    def __str__(self):
        string = f"Playlist for '{self._folder}' (recursive={self._recursive})\n"
        if len(self.playlist) == 0:
            string += "    -- empty --"
        for idx, e in enumerate(self.playlist):
            string += f"{idx:>4}: {e}\n"
        return string
