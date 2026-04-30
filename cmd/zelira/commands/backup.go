package commands

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

func init() {
	backupCmd.Flags().StringVarP(&backupOutput, "output", "o", "", "output file path (default: zelira-backup-<timestamp>.tar.gz)")
	rootCmd.AddCommand(backupCmd)
	rootCmd.AddCommand(restoreCmd)
}

var backupOutput string

var backupDirs = []string{
	"/srv/pihole/etc-pihole",
	"/srv/pihole/etc-dnsmasq.d",
	"/srv/unbound",
	"/srv/kea/etc-kea",
	"/srv/kea/lib-kea",
}

var backupFiles = []string{
	"/etc/systemd/system/container-unbound.service",
	"/etc/systemd/system/container-pihole.service",
	"/etc/systemd/system/container-kea-dhcp4.service",
	"/etc/systemd/system/dns-healthcheck.service",
	"/etc/systemd/system/dns-healthcheck.timer",
	"/usr/local/bin/dns-healthcheck.sh",
}

var backupCmd = &cobra.Command{
	Use:   "backup",
	Short: "Export Zelira config and data to a tarball",
	Long: `Create a compressed backup of all Zelira configuration and data:
  • Pi-hole gravity database and blocklists
  • Pi-hole custom DNS config
  • Unbound config
  • Kea DHCP config and lease database
  • Systemd unit files
  • Health check script

Output: zelira-backup-<timestamp>.tar.gz`,
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: backup requires root (reads /srv/). Run: sudo zelira backup")
			os.Exit(1)
		}

		outFile := backupOutput
		if outFile == "" {
			outFile = fmt.Sprintf("zelira-backup-%s.tar.gz", time.Now().Format("2006-01-02-150405"))
		}

		f, err := os.Create(outFile)
		if err != nil {
			fmt.Printf("Error creating %s: %v\n", outFile, err)
			os.Exit(1)
		}
		defer f.Close()

		gw := gzip.NewWriter(f)
		defer gw.Close()
		tw := tar.NewWriter(gw)
		defer tw.Close()

		count := 0

		// Add config/.env if it exists
		envPath := findFile("config/.env")
		if envPath != "" {
			if err := addFileToTar(tw, envPath, "config/.env"); err == nil {
				count++
			}
		}

		// Add directories
		for _, dir := range backupDirs {
			n, _ := addDirToTar(tw, dir)
			count += n
		}

		// Add individual files
		for _, path := range backupFiles {
			if err := addFileToTar(tw, path, path); err == nil {
				count++
			}
		}

		fmt.Printf("✓ Backed up %d files to %s\n", count, outFile)
	},
}

var restoreCmd = &cobra.Command{
	Use:   "restore <backup.tar.gz>",
	Short: "Restore Zelira from a backup tarball",
	Long:  `Extract a zelira backup tarball, restoring all config and data files.`,
	Args:  cobra.ExactArgs(1),
	Run: func(cmd *cobra.Command, args []string) {
		if os.Geteuid() != 0 {
			fmt.Println("Error: restore requires root. Run: sudo zelira restore <file>")
			os.Exit(1)
		}

		archivePath := args[0]
		f, err := os.Open(archivePath)
		if err != nil {
			fmt.Printf("Error opening %s: %v\n", archivePath, err)
			os.Exit(1)
		}
		defer f.Close()

		gr, err := gzip.NewReader(f)
		if err != nil {
			fmt.Printf("Error reading gzip: %v\n", err)
			os.Exit(1)
		}
		defer gr.Close()

		tr := tar.NewReader(gr)
		count := 0
		for {
			hdr, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				fmt.Printf("Error reading tar: %v\n", err)
				os.Exit(1)
			}

			target := "/" + strings.TrimPrefix(hdr.Name, "/")
			if hdr.Typeflag == tar.TypeDir {
				os.MkdirAll(target, os.FileMode(hdr.Mode))
				continue
			}

			os.MkdirAll(filepath.Dir(target), 0755)
			outFile, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, os.FileMode(hdr.Mode))
			if err != nil {
				fmt.Printf("  ✗ %s: %v\n", target, err)
				continue
			}
			io.Copy(outFile, tr)
			outFile.Close()
			fmt.Printf("  ✓ %s\n", target)
			count++
		}

		fmt.Printf("\n✓ Restored %d files from %s\n", count, archivePath)
		fmt.Println("Run: sudo zelira deploy  (to restart services with restored config)")
	},
}

func addFileToTar(tw *tar.Writer, srcPath, archiveName string) error {
	fi, err := os.Stat(srcPath)
	if err != nil {
		return err
	}
	hdr, err := tar.FileInfoHeader(fi, "")
	if err != nil {
		return err
	}
	hdr.Name = archiveName
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	f, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(tw, f)
	return err
}

func addDirToTar(tw *tar.Writer, dir string) (int, error) {
	count := 0
	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // skip unreadable
		}
		hdr, err := tar.FileInfoHeader(info, "")
		if err != nil {
			return nil
		}
		hdr.Name = path
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if !info.IsDir() {
			f, err := os.Open(path)
			if err != nil {
				return nil
			}
			defer f.Close()
			io.Copy(tw, f)
			count++
		}
		return nil
	})
	return count, err
}
