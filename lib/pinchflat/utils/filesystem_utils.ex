defmodule Pinchflat.Utils.FilesystemUtils do
  @moduledoc """
  Utility methods for working with the filesystem
  """
  require Logger

  alias Pinchflat.Utils.StringUtils

  @doc """
  Checks if a file exists and has non-whitespace contents.

  Returns boolean()
  """
  def exists_and_nonempty?(filepath) do
    case File.read(filepath) do
      {:ok, contents} ->
        String.trim(contents) != ""

      _ ->
        false
    end
  end

  @doc """
  Checks if two filepaths reference the same file.

  Useful if you have a relative and absolute filepath and want to be sure they're the same file.
  Also works with symlinks.

  Returns boolean()
  """
  def filepaths_reference_same_file?(filepath_1, filepath_2) do
    {:ok, stat_1} = File.stat(filepath_1)
    {:ok, stat_2} = File.stat(filepath_2)

    identifier_1 = "#{stat_1.major_device}:#{stat_1.minor_device}:#{stat_1.inode}"
    identifier_2 = "#{stat_2.major_device}:#{stat_2.minor_device}:#{stat_2.inode}"

    identifier_1 == identifier_2
  end

  @doc """
  Generates a temporary file and returns its path. The file is empty and has the given type.
  Generates all the directories in the path if they don't exist.

  Returns binary()
  """
  def generate_metadata_tmpfile(type) do
    filename = StringUtils.random_string(64)
    # This "namespacing" is more to help with development since things get
    # weird in my editor when there are thousands of files in a single directory
    first_two = String.slice(filename, 0..1)
    second_two = String.slice(filename, 2..3)
    tmpfile_directory = Application.get_env(:pinchflat, :tmpfile_directory)

    filepath =
      Path.join([
        tmpfile_directory,
        first_two,
        second_two,
        "#{filename}.#{type}"
      ])

    :ok = write_p!(filepath, "")

    filepath
  end

  @doc """
  Writes content to a file, creating directories as needed.
  Takes the same args as File.write/3.

  Returns :ok | {:error, any()}
  """
  def write_p(file, content, modes \\ []) do
    dirname = Path.dirname(file)

    case File.mkdir_p(dirname) do
      :ok -> File.write(file, content, modes)
      err -> err
    end
  end

  @doc """
  Writes content to a file, creating directories as needed.
  Takes the same args as File.write!/3.

  Returns :ok | raises on error
  """
  def write_p!(filepath, content, modes \\ []) do
    :ok = write_p(filepath, content, modes)
  end

  @doc """
  Writes content to a file that only its owner can read or write (0600), creating directories
  as needed. An existing file's permissions are restricted too. The permissions are restricted
  before the content is written so it's never readable by anyone else. Appending nothing creates
  the file if needed without clearing its current content first.

  Returns :ok | {:error, any()}
  """
  def write_private_file(filepath, content) do
    with :ok <- write_p(filepath, "", [:append]),
         :ok <- File.chmod(filepath, 0o600) do
      File.write(filepath, content)
    end
  end

  @doc """
  Makes sure a directory exists that only the current OS user can access (0700), creating it and
  its parent directories if needed. An existing directory has its permissions restricted, but only
  if it's owned by the current user: whoever owns it could always change them back or add files to it.

  The current user's ID can be given rather than looked up.

  Returns :ok | {:error, {:owned_by, integer()}} | {:error, File.posix()}
  """
  def ensure_private_directory(directory, current_uid \\ current_os_uid()) do
    with :ok <- File.mkdir_p(directory),
         {:ok, %File.Stat{uid: ^current_uid}} <- File.stat(directory) do
      File.chmod(directory, 0o700)
    else
      {:ok, %File.Stat{uid: owner_uid}} -> {:error, {:owned_by, owner_uid}}
      err -> err
    end
  end

  @doc """
  Copies a file from source to destination, creating directories as needed.

  Returns :ok | raises on error
  """
  def cp_p!(source, destination) do
    destination
    |> Path.dirname()
    |> File.mkdir_p!()

    File.cp!(source, destination)
  end

  @doc """
  Checks if a path is inside a directory (at any depth, but not the directory itself) once
  both are expanded. Whole path segments are compared, so `/downloads-other/file` isn't inside
  `/downloads`. Symlinks aren't resolved.

  Returns boolean()
  """
  def inside_directory?(path, directory) do
    directory_parts = Path.split(Path.expand(directory))
    path_parts = Path.split(Path.expand(path))

    List.starts_with?(path_parts, directory_parts) and length(path_parts) > length(directory_parts)
  end

  @doc """
  Deletes a file like `delete_file_and_remove_empty_directories/1`, but only if it's inside the
  given directory (see `inside_directory?/2`). A file anywhere else is left as-is and logged.
  Empty directories are only removed inside the given directory, which is always kept.

  Returns :ok | {:error, :outside_directory} | {:error, any()}
  """
  def delete_file_inside_directory(filepath, directory) do
    if inside_directory?(filepath, directory) do
      delete_file_and_remove_empty_directories(filepath, directory)
    else
      Logger.warning("Not deleting #{inspect(filepath)} since it's outside #{inspect(directory)}")

      {:error, :outside_directory}
    end
  end

  @doc """
  Deletes a file and removes any empty directories in the path.
  Does NOT remove any directories that are not empty.

  Returns :ok | {:error, any()}
  """
  def delete_file_and_remove_empty_directories(filepath) do
    delete_file_and_remove_empty_directories(filepath, nil)
  end

  # Empty directories are only removed inside the boundary directory, if there's one
  defp delete_file_and_remove_empty_directories(filepath, boundary) do
    case File.rm(filepath) do
      :ok ->
        filepath
        |> Path.dirname()
        |> recursively_delete_empty_directories(boundary)

      err ->
        err
    end
  end

  # Erlang can't look up the user the VM runs as
  defp current_os_uid do
    {output, 0} = System.cmd("id", ["-u"])

    String.to_integer(String.trim(output))
  end

  defp recursively_delete_empty_directories(directory, boundary) do
    removable = is_nil(boundary) or inside_directory?(directory, boundary)

    if removable and File.rmdir(directory) == :ok do
      directory
      |> Path.dirname()
      |> recursively_delete_empty_directories(boundary)
    end

    :ok
  end
end
