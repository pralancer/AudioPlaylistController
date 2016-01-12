/*

Copyright (c) 2016 Pralancer

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation 
files (the "Software"), to deal in the Software without restriction, including without limitation the rights to 
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to 
whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE 
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR 
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR 
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

*/

import UIKit
import MediaPlayer

/*** This view controllers is used to integrate the device music library into your apps. When the collection is empty it 
 will show a prompt which can be configured and a button to create the music queue. Once the queue is selected set
 it will show the songs in the queue and play it one by one.
*/
class PKAudioPlaylistController: UIViewController, MPMediaPickerControllerDelegate, UITableViewDelegate, UITableViewDataSource {

    @IBOutlet weak var emptyCollectionLabel: UILabel! //message label
    @IBOutlet weak var setupButton:UIButton! //Button in the main view to bring up the media picker
    @IBOutlet weak var playListTableView: UITableView! //the playlist table view
    @IBOutlet weak var playerControlsView:UIToolbar! //the play controls toolbar
    @IBOutlet weak var playbackDurationBarButton:UIBarButtonItem! //playback duration caption bar button
    @IBOutlet weak var playBarButton:UIBarButtonItem! //play bar button
    @IBOutlet weak var pauseBarButton :UIBarButtonItem! //pause bar button
    @IBOutlet weak var stopBarButton :UIBarButtonItem! //stop bar button
    @IBOutlet weak var clearPlaylistBarButton:UIBarButtonItem! //trash icon for clearing the playlist
    
    private let kPlaylistViewCellID = "PlaylistCellID" //reusable cell id

    var mediaTypes:MPMediaType = .AnyAudio //which media types to support. Currently only audio is supported
    var selectedMediaCollection:MPMediaItemCollection? //The media item queue that is set by the media picker
    var playListCount : Int { //the number of items in the playlist
        if selectedMediaCollection != nil {
            return selectedMediaCollection!.items.count
        }
        return 0
    }
    weak var player:MPMusicPlayerController! = MPMusicPlayerController.systemMusicPlayer() //Music Player to use. Default is the systemMusicPlayer
    var allowMultiplesItems=true //allow multiple item selection
    var showsCloudItems = true //show show cloud items
    var musicPickerPrompt = "Add Music" //prompt for the media picker view controller
    var emptyCollectionPrompt:String = "Setup your empty playlist by clicking the + button" //message for empty collection
    var showSongDurationOnAlbumImage = true //determine if the song duration has to be overlaid on the album image
    var placeholderAlbumImage:UIImage! //set the default placeholder image to use if a media item does not contain album artwork
    var persistCollection = true
    
    private var playDurationTimer:dispatch_source_t!
    private var currentPlayingItemIndex = NSNotFound
    static private var savedMediaCollection:MPMediaItemCollection!
    
    //MARK: -
    
    /*** You should use this method to get a instance of this view controller. It requires the PKAudioPlaylistController xib
    file which contains the view and controller.
    */
    class func instance() -> PKAudioPlaylistController?
    {
        var vc:PKAudioPlaylistController?
        let bundle = NSBundle(forClass: PKAudioPlaylistController.self)
        if let objects = bundle.loadNibNamed("PKAudioPlaylistController", owner: nil, options: nil)
        {
            vc = objects[0] as? PKAudioPlaylistController
        }
        return vc
    }
    
    //MARK: -

    override func viewDidLoad()
    {
        super.viewDidLoad()

        //register a custom table cell class for the playlist table view
        playListTableView.registerClass(PKMediaLibraryItemCell.self, forCellReuseIdentifier: kPlaylistViewCellID)
        playListTableView.allowsMultipleSelection = false //dont allow multiple selection for playback
        
        //Add a + button to the navigation to trigger the media picker
        let addMoreButton = UIBarButtonItem(barButtonSystemItem: UIBarButtonSystemItem.Add, target: self, action: "setupPlaylist:")
        self.navigationItem.rightBarButtonItem = addMoreButton
    
        if persistCollection
        {
            selectedMediaCollection = PKAudioPlaylistController.savedMediaCollection
        }
        
        
        //register for notifications
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "playbackStateChanged:", name: MPMusicPlayerControllerPlaybackStateDidChangeNotification, object: player)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "nowPlayingItemChanged:", name: MPMusicPlayerControllerNowPlayingItemDidChangeNotification, object: player)
        player.beginGeneratingPlaybackNotifications()
        //default player shuffle and repeat modes
        player.shuffleMode = MPMusicShuffleMode.Off
        player.repeatMode = MPMusicRepeatMode.None
        player.setQueueWithItemCollection(MPMediaItemCollection(items: []))
        setupPlayDurationTimer()
        
        updateUI()
    }

    deinit
    {
        player.endGeneratingPlaybackNotifications()
        NSNotificationCenter.defaultCenter().removeObserver(self)
        if persistCollection
        {
            PKAudioPlaylistController.savedMediaCollection = selectedMediaCollection
        }
        else
        {
            PKAudioPlaylistController.savedMediaCollection = nil
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    //MARK: Player notifications
    
    func playbackStateChanged(notification:NSNotification)
    {
//        print("playbackStateChanged = \(notification)")
        updatePlayerControls() //update the playback controls
    }
    
    func nowPlayingItemChanged(notification:NSNotification)
    {
//        print("nowPlayingItemChanged = \(notification)")
        updatePlaylistTable()
    }

    /*** Timer dispatch to update the current playback duration of the currently playing media item. Triggered every second */
    func setupPlayDurationTimer()
    {
        playDurationTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue())
        dispatch_source_set_timer(playDurationTimer, DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC, 0 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(playDurationTimer) {
            [unowned self] in
            if self.player.playbackState == .Playing
            {
                let index = self.indexOfCurrentlyPlayingItem()
                if index != NSNotFound
                {
                    let nowPlayingIndexPath = NSIndexPath(forRow: index, inSection: 0)
                    if index < self.playListCount
                    {
                        if let cell = self.playListTableView.cellForRowAtIndexPath(nowPlayingIndexPath) as? PKMediaLibraryItemCell,
                        playingItem = self.player.nowPlayingItem
                        {
                            //set the current playback time to the accessory label and the bar button item
                            let remaining = playingItem.playbackDuration - self.player.currentPlaybackTime
                            if !remaining.isNaN //In rare occassions this can be a NaN. So check before converting it into a strings
                            {
                                cell.accessoryView = cell.labelForPlayTime(remaining)
                                self.playbackDurationBarButton.title = remaining.formattedTimeStr()
                            }
                            else
                            {
                                print("NaN playingItem.playbackDuration = \(playingItem.playbackDuration)")
                                print("NaN self.player.currentPlaybackTime = \(self.player.currentPlaybackTime)")
                            }
                        }
                    }
                }
            }
        }
        dispatch_resume(playDurationTimer);
    }
    
    //MARK: User Actions
    
    /** Calls the media picker controller to select the songs */
    @IBAction func setupPlaylist(sender:AnyObject?)
    {
        let musicPicker = MPMediaPickerController(mediaTypes: mediaTypes)
        musicPicker.delegate = self
        musicPicker.allowsPickingMultipleItems = allowMultiplesItems
        musicPicker.showsCloudItems = showsCloudItems
        musicPicker.prompt = musicPickerPrompt
        self.presentViewController(musicPicker, animated: true, completion: nil)
    }
    
    @IBAction func play(sender:AnyObject?)
    {
        if player.playbackState == .Paused || player.playbackState == .Stopped
        {
            player.play()
        }
    }
    
    @IBAction func pause(sender:AnyObject?)
    {
        if player.playbackState != .Paused
        {
            player.pause()
        }
    }
    
    @IBAction func stop(sender:AnyObject?)
    {
        if player.playbackState != .Stopped
        {
            player.stop()
        }
    }
    
    @IBAction func clearPlaylist(sender:AnyObject?)
    {
        selectedMediaCollection = nil
        player.stop()
        player.nowPlayingItem = nil
        self.player.setQueueWithItemCollection(MPMediaItemCollection(items: []))
        updateUI()
    }
    
    //MARK: UI updates
    
    /* Show or hide the table view */
    func updateUI()
    {
        if playListCount == 0
        {
            emptyCollectionLabel.hidden = false
            setupButton.hidden = false
            playListTableView.hidden = true
            playerControlsView.hidden = true
            emptyCollectionLabel.text = emptyCollectionPrompt
        }
        else
        {
            emptyCollectionLabel.hidden = true
            setupButton.hidden = true
            playListTableView.hidden = false
            playerControlsView.hidden = false
            playListTableView.reloadData()
            updatePlayerControls()
            updatePlaylistTable()
        }
    }

    /*** Updates the player controls based on the current state of the player */
    func updatePlayerControls()
    {
        switch self.player.playbackState
        {
        case .Playing:
            playBarButton.enabled = false
            pauseBarButton.enabled = true
            stopBarButton.enabled = true
        case .Paused:
            playBarButton.enabled = true
            pauseBarButton.enabled = false
            stopBarButton.enabled = true
        case .Stopped:
            playBarButton.enabled = true
            pauseBarButton.enabled = false
            stopBarButton.enabled = false
        default:
            break
        }
    }
    
    /** Returns the index of the currently playing item if its in our queue. If not returns NSNotFound */
    func indexOfCurrentlyPlayingItem() -> Int
    {
        if let nowPlayingItem = self.player.nowPlayingItem, items = selectedMediaCollection?.items
        {
            for mediaItem:MPMediaItem in items
            {
                if nowPlayingItem.persistentID == mediaItem.persistentID {
                    return items.indexOf(mediaItem)!
                }
            }
        }
        return NSNotFound
    }
    
    /*** Updates the state of the playlist table based on the currently playing item */
    func updatePlaylistTable()
    {
        let index = indexOfCurrentlyPlayingItem()
        
        //deselect the currently selected row and reset its play duration
        if currentPlayingItemIndex != NSNotFound && //we have something playing
            currentPlayingItemIndex < playListCount && //and its within the current queue
            currentPlayingItemIndex != index //and its not the same as the current one
        {
            //to reset the playback time to the media time for the currently playing song
            playListTableView.reloadRowsAtIndexPaths([NSIndexPath(forRow: currentPlayingItemIndex, inSection: 0)], withRowAnimation: UITableViewRowAnimation.Automatic)
        }
        
        //select the newly playing item
        if index != NSNotFound
        {
            playListTableView.selectRowAtIndexPath(NSIndexPath(forRow: index, inSection: 0),
                animated: true, scrollPosition: UITableViewScrollPosition.Bottom)
            currentPlayingItemIndex = index
        }
        
        //reset the timer caption. It will be set in the timer
        if index == NSNotFound
        {
            self.playbackDurationBarButton.title = ""
        }
    }
    
    //MARK: Model update

    /** Adds a new collection to your queue, adding it at the end of the queue if one is available */
    func addMediaItemCollection(mediaItemCollection:MPMediaItemCollection)
    {
        //if our collection is empty then just assign the new collection to it
        if selectedMediaCollection == nil
        {
            selectedMediaCollection = mediaItemCollection
            player.setQueueWithItemCollection(selectedMediaCollection!)
        }
        else //add the newly selected items to the bottom of the list
        {
            let currentItems = selectedMediaCollection!.items + mediaItemCollection.items
            selectedMediaCollection = MPMediaItemCollection(items:currentItems)
            player.setQueueWithItemCollection(selectedMediaCollection!)
        }
    }
    
    /** Sets the playing item to a specified index in the current queue */
    func setPlayingItemIndex(index:Int)
    {
        playbackDurationBarButton.title = ""
        //if the index is within the current range of the queue
        if let mediaItems = selectedMediaCollection?.items where index < mediaItems.count
        {
            //note down the previous state of the player
            let wasPlaying = player.playbackState == .Playing
            if wasPlaying {
                player.stop()
            }
            
            player.setQueueWithItemCollection(selectedMediaCollection!)
            //change the now playing item to the newly selected media item
            self.player.nowPlayingItem = mediaItems[index]
            
            //if the player was playing earlier then continue to play
            player.play()
        }
    }
}

//MARK: Table delegate

extension PKAudioPlaylistController
{
    func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return playListCount
    }

    func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let cell:PKMediaLibraryItemCell = tableView.dequeueReusableCellWithIdentifier(kPlaylistViewCellID, forIndexPath: indexPath) as! PKMediaLibraryItemCell

        if let mediaItem = selectedMediaCollection?.items[indexPath.row]
        {
            cell.configureItem(mediaItem, tableView:tableView, overlaySongDuration: showSongDurationOnAlbumImage, placeholderImage:placeholderAlbumImage)
        }
        return cell
    }
    
    func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        setPlayingItemIndex(indexPath.row)
    }
    
}

//MARK: MPPickerController delegate

extension PKAudioPlaylistController
{
    func mediaPickerDidCancel(mediaPicker: MPMediaPickerController) {
        self.dismissViewControllerAnimated(true, completion: nil)
    }
    
    func mediaPicker(mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection)
    {
        if mediaItemCollection.items.count > 0
        {
            var items = Array(Set(mediaItemCollection.items)) //remove duplicates using Set
            items = items.sort({ (mediaItem1, mediaItem2) -> Bool in
                return mediaItem1.persistentID < mediaItem2.persistentID
            })
            addMediaItemCollection(MPMediaItemCollection(items: items))
            self.updateUI()
            self.dismissViewControllerAnimated(true,completion: nil)
        }
    }
    
}

//MARK: -

class PKMediaLibraryItemCell : UITableViewCell
{
    required init?(coder:NSCoder)
    {
        super.init(coder:coder)
    }
    
    override init(style: UITableViewCellStyle, reuseIdentifier: String?)
    {
        super.init(style:.Subtitle, reuseIdentifier:reuseIdentifier)
    }
    
    func configureItem(mediaItem:MPMediaItem, tableView:UITableView, overlaySongDuration:Bool = true, placeholderImage:UIImage? = nil)
    {
        self.textLabel?.text = mediaItem.title //set the title
        if let artist = mediaItem.artist {
            self.detailTextLabel?.text = artist
        } else if let albumArtist = mediaItem.albumArtist {
            self.detailTextLabel?.text = albumArtist
        } else if let albumTitle = mediaItem.albumTitle {
            self.detailTextLabel?.text = albumTitle
        }
        
        //set the album image if available from the media item, if not set the placeholder image if set other clear the image
        let durationStr:String? = overlaySongDuration ? mediaItem.playbackDuration.formattedTimeStr() : nil
        if let artwork = mediaItem.artwork, image = artwork.imageWithSize(artwork.imageCropRect.size)
        {
            self.imageView?.clipsToBounds = true
            self.imageView?.contentMode = .Center
            self.imageView?.image = image.resizedImageWithSize(CGSizeMake(tableView.rowHeight-2,tableView.rowHeight-2), overlayString:durationStr)
        }
        else if placeholderImage != nil
        {
            self.imageView?.image = placeholderImage!.resizedImageWithSize(CGSizeMake(tableView.rowHeight-2,tableView.rowHeight-2), overlayString:durationStr)
        }
        else
        {
            self.imageView?.image = nil
        }
        
        //set the media time time as accessory label
        self.accessoryView = labelForPlayTime(mediaItem.playbackDuration)
    }
    
    func labelForPlayTime(seconds:NSTimeInterval) -> UILabel
    {
        let label = UILabel(frame: CGRectMake(0, 0, 0, 12))
        label.text = seconds.formattedTimeStr()
        label.font = UIFont.systemFontOfSize(12)
        label.sizeToFit()
        return label
    }
}

//MARK: -
extension UIImage
{
    func resizedImageWithSize(size:CGSize, overlayString:String? = nil) -> UIImage
    {
        var textlayer:CATextLayer!
        if let str = overlayString
        {
            textlayer = CATextLayer()
            textlayer.frame = CGRectMake(0, -20, size.width, size.height * 0.25)
            textlayer.string = str
            textlayer.font = UIFont.systemFontOfSize(0)
            textlayer.fontSize = size.height * 0.25 - 2.0
            textlayer.alignmentMode = "center"
            textlayer.contentsGravity = kCAGravityCenter
            textlayer.foregroundColor = UIColor.whiteColor().CGColor
            textlayer.backgroundColor = UIColor.blackColor().colorWithAlphaComponent(0.5).CGColor
            textlayer.contentsScale = self.scale
        }
        
        UIGraphicsBeginImageContextWithOptions(size, true, self.scale)

        self.drawInRect(CGRectMake(0, 0, size.width, size.height))
        
        UIGraphicsPushContext(UIGraphicsGetCurrentContext()!)
        CGContextTranslateCTM(UIGraphicsGetCurrentContext()!, 0, size.height * 0.75)
        if textlayer != nil {
            textlayer.renderInContext(UIGraphicsGetCurrentContext()!)
        }
        UIGraphicsPopContext()
        
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image != nil ? image : self
    }
}

extension NSTimeInterval
{
    static let formatter:NSDateComponentsFormatter = {
        return NSDateComponentsFormatter()
    } ()
    
    func formattedTimeStr() -> String?
    {
        if self > 3600 {
            NSTimeInterval.formatter.allowedUnits = [.Hour, .Minute, .Second]
        } else {
            NSTimeInterval.formatter.allowedUnits = [.Minute, .Second]
        }
        NSTimeInterval.formatter.zeroFormattingBehavior = .Pad
        return NSTimeInterval.formatter.stringFromTimeInterval(self)
    }
}